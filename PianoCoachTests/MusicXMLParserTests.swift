import Foundation
import Testing
@testable import PianoCoach

/// 拼一个最小的 score-partwise 文档
private func doc(title: String? = nil, parts: [String]) -> Data {
    let list = parts.indices.map { "<score-part id=\"P\($0 + 1)\"><part-name>P\($0 + 1)</part-name></score-part>" }
    let body = parts.enumerated().map { "<part id=\"P\($0.offset + 1)\">\($0.element)</part>" }
    let work = title.map { "<work><work-title>\($0)</work-title></work>" } ?? ""
    return Data("""
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE score-partwise PUBLIC "-//Recordare//DTD MusicXML 4.0 Partwise//EN" "http://www.musicxml.org/dtds/partwise.dtd">
    <score-partwise version="4.0">\(work)<part-list>\(list.joined())</part-list>\(body.joined())</score-partwise>
    """.utf8)
}

private func note(_ step: String, _ octave: Int, _ duration: Int, alter: Int? = nil,
                  extra: String = "", staff: Int? = nil, voice: Int? = nil) -> String {
    let a = alter.map { "<alter>\($0)</alter>" } ?? ""
    let s = staff.map { "<staff>\($0)</staff>" } ?? ""
    let v = voice.map { "<voice>\($0)</voice>" } ?? ""
    return "<note>\(extra.contains("<chord/>") ? "<chord/>" : "")<pitch><step>\(step)</step>\(a)<octave>\(octave)</octave></pitch><duration>\(duration)</duration>\(extra.replacingOccurrences(of: "<chord/>", with: ""))\(v)\(s)</note>"
}

private func rest(_ duration: Int) -> String { "<note><rest/><duration>\(duration)</duration></note>" }

private func attrs(divisions: Int = 1, beats: String = "4", beatType: Int = 4,
                   fifths: Int = 0, staves: Int? = nil, clefs: String = "") -> String {
    let st = staves.map { "<staves>\($0)</staves>" } ?? ""
    return "<attributes><divisions>\(divisions)</divisions><key><fifths>\(fifths)</fifths></key><time><beats>\(beats)</beats><beat-type>\(beatType)</beat-type></time>\(st)\(clefs)</attributes>"
}

private func midis(_ notes: [ScoreNote]) -> [Int] { notes.map(\.midi) }
private func beats(_ notes: [ScoreNote]) -> [Double] { notes.map(\.beat) }

struct MusicXMLParserTests {

    @Test func simpleMelody() throws {
        let m = "<measure number=\"1\">\(attrs(divisions: 2))<direction><sound dynamics=\"80\"/></direction><direction><sound tempo=\"100\"/></direction>"
            + note("C", 4, 2) + note("D", 4, 1) + note("E", 4, 1) + note("F", 4, 4, alter: 1)
            + "</measure>"
        let score = try MusicXMLParser.parse(data: doc(title: "小测试", parts: [m]))

        #expect(score.title == "小测试")
        #expect(score.defaultBPM == 100)
        #expect(midis(score.notes) == [60, 62, 64, 66])
        #expect(beats(score.notes) == [0, 1, 1.5, 2])
        #expect(score.notes.map(\.duration) == [1, 0.5, 0.5, 2])
        #expect(score.notes.allSatisfy { $0.hand == .right })
        #expect(score.barStarts == [0])
        #expect(score.endBeat == 4)
    }

    @Test func fallbackTitleAndDefaultTempo() throws {
        let m = "<measure>\(attrs())\(note("C", 4, 4))</measure>"
        let score = try MusicXMLParser.parse(data: doc(parts: [m]), fallbackTitle: "文件名")
        #expect(score.title == "文件名")
        #expect(score.defaultBPM == 80)
    }

    @Test func grandStaffChordsAndBackup() throws {
        let clefs = "<clef number=\"1\"><sign>G</sign><line>2</line></clef><clef number=\"2\"><sign>F</sign><line>4</line></clef>"
        let m = "<measure>\(attrs(staves: 2, clefs: clefs))"
            + note("C", 5, 2, staff: 1, voice: 1)
            + note("E", 5, 2, extra: "<chord/>", staff: 1, voice: 1)
            + note("G", 5, 2, staff: 1, voice: 1)
            + "<backup><duration>4</duration></backup>"
            + note("C", 3, 4, staff: 2, voice: 5)
            + "</measure>"
        let score = try MusicXMLParser.parse(data: doc(parts: [m]))

        let right = score.notes(for: .right)
        #expect(midis(right) == [72, 76, 79])
        #expect(beats(right) == [0, 0, 2])
        let left = score.notes(for: .left)
        #expect(midis(left) == [48])
        #expect(left[0].beat == 0 && left[0].duration == 4)

        #expect(score.steps(for: .right).map(midis) == [[72, 76], [79]])
        #expect(score.endBeat == 4)
        // id 唯一且连续
        #expect(score.notes.map(\.id) == Array(0..<score.notes.count))
    }

    @Test func tiesAreMerged() throws {
        let m1 = "<measure>\(attrs())\(note("C", 4, 2))\(note("C", 4, 2, extra: "<tie type=\"start\"/>"))</measure>"
        let m2 = "<measure>\(note("C", 4, 4, extra: "<tie type=\"stop\"/>"))</measure>"
        let score = try MusicXMLParser.parse(data: doc(parts: [m1 + m2]))

        #expect(midis(score.notes) == [60, 60])
        #expect(beats(score.notes) == [0, 2])
        #expect(score.notes.map(\.duration) == [2, 6])
        #expect(score.barStarts == [0, 4])
        #expect(score.endBeat == 8)
    }

    @Test func pickupMeasure() throws {
        let m0 = "<measure number=\"0\" implicit=\"yes\">\(attrs(beats: "3"))\(note("G", 4, 1))</measure>"
        let m1 = "<measure number=\"1\">\(note("C", 5, 3))</measure>"
        let m2 = "<measure number=\"2\">\(rest(3))</measure>"
        let score = try MusicXMLParser.parse(data: doc(parts: [m0 + m1 + m2]))

        #expect(score.barStarts == [0, 1, 4])
        #expect(score.endBeat == 7)
        #expect(beats(score.notes) == [0, 1])
        #expect(score.barIndex(at: 0.5) == 0)
        #expect(score.barIndex(at: 1) == 1)
        #expect(score.barIndex(at: 6.9) == 2)
        #expect(score.barLength(1) == 3)
    }

    @Test func compoundMeterAndEmptyMeasure() throws {
        let m1 = "<measure>\(attrs(divisions: 2, beats: "6", beatType: 8))\(note("C", 4, 6))</measure>"
        let m2 = "<measure></measure>"
        let m3 = "<measure>\(note("D", 4, 6))</measure>"
        let score = try MusicXMLParser.parse(data: doc(parts: [m1 + m2 + m3]))

        // 6/8 = 3 个四分音符拍；空小节按拍号补长度
        #expect(score.barStarts == [0, 3, 6])
        #expect(beats(score.notes) == [0, 6])
    }

    @Test func repeatsWithEndings() throws {
        let m1 = "<measure><barline location=\"left\"><repeat direction=\"forward\"/></barline>\(attrs())\(note("C", 4, 4))</measure>"
        let m2 = "<measure>\(note("D", 4, 4))</measure>"
        let m3 = "<measure><barline location=\"left\"><ending number=\"1\" type=\"start\"/></barline>\(note("E", 4, 4))<barline location=\"right\"><ending number=\"1\" type=\"stop\"/><repeat direction=\"backward\"/></barline></measure>"
        let m4 = "<measure><barline location=\"left\"><ending number=\"2\" type=\"start\"/></barline>\(note("F", 4, 4))<barline location=\"right\"><ending number=\"2\" type=\"discontinue\"/></barline></measure>"
        let m5 = "<measure>\(note("G", 4, 4))</measure>"
        let score = try MusicXMLParser.parse(data: doc(parts: [m1 + m2 + m3 + m4 + m5]))

        #expect(midis(score.notes) == [60, 62, 64, 60, 62, 65, 67])
        #expect(beats(score.notes) == [0, 4, 8, 12, 16, 20, 24])
        #expect(score.barCount == 7)
    }

    @Test func simpleRepeatTwiceThenNextSection() throws {
        let m1 = "<measure>\(attrs())\(note("C", 4, 4))<barline location=\"right\"><repeat direction=\"backward\"/></barline></measure>"
        let m2 = "<measure><barline location=\"left\"><repeat direction=\"forward\"/></barline>\(note("D", 4, 4))<barline location=\"right\"><repeat direction=\"backward\" times=\"3\"/></barline></measure>"
        let m3 = "<measure>\(note("E", 4, 4))</measure>"
        let score = try MusicXMLParser.parse(data: doc(parts: [m1 + m2 + m3]))
        #expect(midis(score.notes) == [60, 60, 62, 62, 62, 64])
    }

    @Test func separateTrebleAndBassParts() throws {
        let rh = "<measure>\(attrs(clefs: "<clef><sign>G</sign><line>2</line></clef>"))\(note("E", 4, 4))</measure>"
        let lh = "<measure>\(attrs(clefs: "<clef><sign>F</sign><line>4</line></clef>"))\(note("C", 3, 4))</measure>"
        let score = try MusicXMLParser.parse(data: doc(parts: [rh, lh]))
        #expect(midis(score.notes(for: .right)) == [64])
        #expect(midis(score.notes(for: .left)) == [48])
    }

    @Test func pianoPartPreferredOverVoice() throws {
        let voice = "<measure>\(attrs())\(note("A", 5, 4))</measure>"
        let piano = "<measure>\(attrs(staves: 2))\(note("C", 4, 4, staff: 1))<backup><duration>4</duration></backup>\(note("C", 3, 4, staff: 2))</measure>"
        let score = try MusicXMLParser.parse(data: doc(parts: [voice, piano]))
        #expect(midis(score.notes) == [60, 48])
    }

    @Test func graceNotesIgnoredRestsAdvance() throws {
        let grace = "<note><grace/><pitch><step>B</step><octave>3</octave></pitch><type>eighth</type></note>"
        let m = "<measure>\(attrs())\(rest(1))\(grace)\(note("C", 4, 1))<note><cue/><pitch><step>D</step><octave>4</octave></pitch><duration>1</duration></note>\(note("E", 4, 1, alter: -1))</measure>"
        let score = try MusicXMLParser.parse(data: doc(parts: [m]))
        #expect(midis(score.notes) == [60, 63])
        #expect(beats(score.notes) == [1, 3])
    }

    @Test func keySignatureAndTempoClamp() throws {
        let m = "<measure>\(attrs(fifths: -3))<sound tempo=\"200\"/>\(note("B", 4, 4, alter: -1))</measure>"
        let score = try MusicXMLParser.parse(data: doc(parts: [m]))
        #expect(score.keyFifths == -3)
        #expect(score.defaultBPM == 120)
        #expect(score.notes.first?.midi == 70)
    }

    @Test func compressedMXL() throws {
        let data = try #require(Data(base64Encoded: mxlFixture))
        let score = try MusicXMLParser.parse(data: data)
        #expect(score.title == "MXL Test")
        #expect(midis(score.notes) == [60, 62, 64, 65])
    }

    /// Samples/导入测试曲 端到端：期望值来自 music21（expandRepeats + stripTies）
    @Test(arguments: ["导入测试曲.musicxml", "导入测试曲.mxl"])
    func sampleFile(_ name: String) throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Samples").appendingPathComponent(name)
        let score = try MusicXMLParser.parse(data: Data(contentsOf: url))

        #expect(score.title == "导入测试曲")
        #expect(score.defaultBPM == 76)
        #expect(score.keyFifths == -1)
        #expect(score.barStarts == [0, 1, 4, 7, 10, 13, 16, 19])
        #expect(score.endBeat == 22)

        let right = score.notes(for: .right)
        #expect(midis(right) == [72, 77, 81, 84, 82, 81, 79, 77, 81, 84, 82, 81, 77])
        #expect(beats(right) == [0, 1, 2, 3, 4, 6, 7, 10, 11, 12, 13, 15, 16])
        #expect(right.last?.duration == 5)      // 跨小节连音线合并

        #expect(score.steps(for: .left).map(midis)
                == [[53, 57, 60], [48, 58], [48], [53, 57, 60], [48, 58], [41, 53]])
        #expect(beats(score.steps(for: .left).map { $0[0] }) == [1, 4, 7, 10, 13, 16])
    }

    @Test func rejectsNonMusicXML() {
        #expect(throws: MusicXMLError.notMusicXML) {
            try MusicXMLParser.parse(data: Data("<html><body/></html>".utf8))
        }
        #expect(throws: MusicXMLError.notMusicXML) {
            try MusicXMLParser.parse(data: Data("not xml at all".utf8))
        }
        #expect(throws: MusicXMLError.timewiseUnsupported) {
            try MusicXMLParser.parse(data: Data("<score-timewise/>".utf8))
        }
        #expect(throws: MusicXMLError.noNotes) {
            try MusicXMLParser.parse(data: doc(parts: ["<measure>\(attrs())\(rest(4))</measure>"]))
        }
    }
}

struct ScoreModelTests {

    @Test func sampleScoresKeepTheirBars() {
        let twinkle = SampleScores.twinkle
        #expect(twinkle.barCount == 4)
        #expect(twinkle.barStarts == [0, 4, 8, 12])
        #expect(twinkle.barIndex(at: 7.99) == 1)
        #expect(twinkle.barIndex(at: 100) == 3)
        #expect(twinkle.steps(for: .right).count == 14)
    }

    @Test func flatsInFlatKeys() {
        #expect(StaffPosition.make(midi: 70).accidental == "♯")
        let flat = StaffPosition.make(midi: 70, preferFlats: true)   // B♭4
        #expect(flat.accidental == "♭")
        #expect(flat.diatonic == StaffPosition.make(midi: 71).diatonic)
        #expect(StaffPosition.make(midi: 61, preferFlats: true).diatonic
                == StaffPosition.make(midi: 62).diatonic)          // D♭4 写在 D 上
        #expect(StaffPosition.make(midi: 60, preferFlats: true).accidental == nil)
    }
}

/// 用 Python zipfile 生成的 .mxl（含 mimetype、META-INF/container.xml、deflate 压缩的 score.musicxml）
private let mxlFixture = "UEsDBBQAAAAAAMNNU10uQhWCIgAAACIAAAAIAAAAbWltZXR5cGVhcHBsaWNhdGlvbi92bmQucmVjb3JkYXJlLm11c2ljeG1sUEsDBBQAAAAIAMNNU103duskYQAAAHsAAAAWAAAATUVUQS1JTkYvY29udGFpbmVyLnhtbE3MMRJAMBBA0d4pMtsTOkUSnRNwABOLnYldk4RxfDq63/xnunsP6sKYSNhCU9WgkL3MxKuFcejLFjpXGC+cJ2KMzkSRvFDA9KVazhDKY8qbheQlYrWfifxLg3ZG/w79QQ9QSwMEFAAAAAgAw01TXZ4MFpoHAQAAvgIAAA4AAABzY29yZS5tdXNpY3htbK2SsW6EMAyGd54CsdMU6YYOxje0vamVbrhKXQNYrXWQoMRw7ds3EE5Qdewtif3b/mLLgf1X16YjOc/WlFlxd5+lZGrbsPkos7fTIX/I9piAr62jvNdOLuxpLdiFAoSLded45sLSEr6+v6Qn8gJqI0YnwCZM3rIX3HBTbsrsWATaHDa6IzyyNhbUKoBaC3AJzKAIXRkdaT84Ss3QVeTCYEHTIo6rQcgjNDzyNIHHAtTqgPD0SkVaPO5ARWP2c/nu6apFB1RMVxtyAsZK0HqW+jPMJ9TjY2h7usHWoscZslhhhJjXDE5LaGFu52qDiqy/xKebE59vTjz8j5iAWpa4LPrX8qdfiMkPUEsBAhQDFAAAAAAAw01TXS5CFYIiAAAAIgAAAAgAAAAAAAAAAAAAAIABAAAAAG1pbWV0eXBlUEsBAhQDFAAAAAgAw01TXTd26yRhAAAAewAAABYAAAAAAAAAAAAAAIABSAAAAE1FVEEtSU5GL2NvbnRhaW5lci54bWxQSwECFAMUAAAACADDTVNdngwWmgcBAAC+AgAADgAAAAAAAAAAAAAAgAHdAAAAc2NvcmUubXVzaWN4bWxQSwUGAAAAAAMAAwC2AAAAEAIAAAAA"
