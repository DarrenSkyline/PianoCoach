import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

enum MusicXMLError: LocalizedError, Equatable {
    case notMusicXML
    case timewiseUnsupported
    case noNotes
    case badArchive(String)

    var errorDescription: String? {
        switch self {
        case .notMusicXML:         return "这不是有效的 MusicXML 文件。"
        case .timewiseUnsupported: return "暂不支持 score-timewise 格式，请在打谱软件里另存为普通 MusicXML。"
        case .noNotes:             return "文件里没有找到可以练习的音符。"
        case .badArchive(let why): return "无法解压 .mxl 文件：\(why)"
        }
    }
}

/// MusicXML（score-partwise）→ Score。
/// 支持：多声部 backup/forward、和弦、连音线合并、双谱表分左右手、弱起小节、
/// 换拍号、反复记号与一/二房（展开成线性顺序）、速度标记、调号。
/// 不支持（忽略）：倚音、D.C./D.S./Coda 跳转、打击乐。
enum MusicXMLParser {

    /// 自动识别 .mxl（zip）和普通 XML
    static func parse(data: Data, fallbackTitle: String = "导入的曲谱") throws -> Score {
        if data.starts(with: [0x50, 0x4B, 0x03, 0x04]) {   // "PK\3\4"
            return try parse(xml: MXLArchive.rootScore(in: data), fallbackTitle: fallbackTitle)
        }
        return try parse(xml: data, fallbackTitle: fallbackTitle)
    }

    static func parse(xml: Data, fallbackTitle: String = "导入的曲谱") throws -> Score {
        guard let root = XMLTree.parse(xml) else { throw MusicXMLError.notMusicXML }
        if root.name == "score-timewise" { throw MusicXMLError.timewiseUnsupported }
        guard root.name == "score-partwise" else { throw MusicXMLError.notMusicXML }

        let title = [root.child("work")?.child("work-title")?.text,
                     root.child("movement-title")?.text]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? fallbackTitle

        var parts = root.elements("part").map(parsePart)
        // 有钢琴大谱表（两行谱）的话只取它，避免把人声、伴奏乐器混进来
        if let piano = parts.first(where: { $0.staves >= 2 }) { parts = [piano] }
        guard let first = parts.first, !first.measures.isEmpty else { throw MusicXMLError.noNotes }

        let measureCount = parts.map { $0.measures.count }.max() ?? 0
        let lengths: [Double] = (0..<measureCount).map { i in
            let content = parts.compactMap { $0.measures[safe: i]?.length }.max() ?? 0
            let nominal = parts.compactMap { $0.measures[safe: i]?.nominalLength }.first ?? 4
            return content > 1e-9 ? content : nominal
        }
        let order = playOrder(first.measures)

        // 按演奏顺序展开
        var raw: [RawNote] = []
        var barStarts: [Double] = []
        var cursor = 0.0
        for index in order {
            barStarts.append(cursor)
            for (p, part) in parts.enumerated() {
                guard let measure = part.measures[safe: index] else { continue }
                for n in measure.notes {
                    var note = n
                    note.beat += cursor
                    note.voiceKey = "\(p)-\(n.voiceKey)"
                    raw.append(note)
                }
            }
            cursor += lengths[index]
        }

        let merged = mergeTies(raw)
        guard !merged.isEmpty else { throw MusicXMLError.noNotes }

        func sortKey(_ n: RawNote) -> (Double, Int, Int) { (n.beat, n.hand == .right ? 0 : 1, n.midi) }
        let sorted = merged.sorted { sortKey($0) < sortKey($1) }
        let notes = sorted.enumerated().map { i, n in
            ScoreNote(id: i, midi: n.midi, beat: n.beat, duration: n.duration, hand: n.hand)
        }
        let bpm = parts.lazy.compactMap { $0.tempo }.first ?? 80
        return Score(title: title,
                     defaultBPM: min(120, max(40, bpm.rounded())),
                     barStarts: barStarts,
                     endBeat: cursor,
                     keyFifths: first.keyFifths ?? 0,
                     notes: notes)
    }

    // MARK: - 中间结构

    struct RawNote {
        var midi: Int
        var beat: Double
        var duration: Double
        var hand: Hand
        var tieStart: Bool
        var tieStop: Bool
        /// 声部标识，连音线只在同一声部内合并
        var voiceKey: String
    }

    struct Measure {
        var length: Double = 0             // 实际内容长度（拍）
        var nominalLength: Double?         // 拍号给出的长度（空小节时用）
        var notes: [RawNote] = []
        var repeatForward = false
        var repeatBackward = false
        var repeatTimes = 2
        var endingStart: [Int]?            // 房子开始：适用的遍数，如 [1] 或 [1, 2]
        var endingStop = false
    }

    struct Part {
        var measures: [Measure] = []
        var staves = 1
        var tempo: Double?
        var keyFifths: Int?
    }

    // MARK: - 解析一个声部

    private static func parsePart(_ node: XMLTree) -> Part {
        var part = Part()
        var divisions = 1.0
        var timeLength = 4.0
        var clefs: [Int: String] = [:]     // 谱表号 → 谱号（G/F/C）

        for m in node.elements("measure") {
            var measure = Measure()
            var cursor = 0.0
            var lastStart = 0.0

            for el in m.children {
                switch el.name {
                case "attributes":
                    if let d = el.child("divisions")?.number, d > 0 { divisions = d }
                    if let s = el.child("staves")?.number { part.staves = Int(s) }
                    if part.keyFifths == nil, let f = el.child("key")?.child("fifths")?.number {
                        part.keyFifths = Int(f)
                    }
                    if let time = el.child("time"),
                       let beats = time.child("beats")?.text,
                       let type = time.child("beat-type")?.number, type > 0 {
                        // "3+2" 这样的复合拍号
                        let total = beats.split(separator: "+").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }.reduce(0, +)
                        if total > 0 { timeLength = total * 4 / type }
                    }
                    for clef in el.elements("clef") {
                        let number = Int(clef.attributes["number"] ?? "1") ?? 1
                        clefs[number] = clef.child("sign")?.text
                    }

                case "note":
                    let isChord = el.child("chord") != nil
                    let duration = (el.child("duration")?.number ?? 0) / divisions
                    if el.child("grace") != nil { continue }            // 倚音不占时值，忽略
                    let start = isChord ? lastStart : cursor
                    if !isChord {
                        lastStart = cursor
                        cursor += duration
                    }
                    measure.length = max(measure.length, cursor)
                    guard el.child("cue") == nil, let pitch = el.child("pitch"),
                          let midi = midiNumber(pitch), duration > 0 else { continue }

                    let staff = Int(el.child("staff")?.text ?? "1") ?? 1
                    let hand: Hand
                    if part.staves >= 2 {
                        hand = staff == 1 ? .right : .left
                    } else {
                        hand = clefs[staff] == "F" ? .left : .right
                    }
                    // <tie> 管发声，<tied> 管画法；有的软件只写其中一个
                    let tieNodes = el.elements("tie") + (el.child("notations")?.elements("tied") ?? [])
                    let ties: [String] = tieNodes.compactMap { $0.attributes["type"] }
                    let voice = el.child("voice")?.text ?? "1"
                    measure.notes.append(RawNote(midi: midi, beat: start, duration: duration, hand: hand,
                                                 tieStart: ties.contains("start"),
                                                 tieStop: ties.contains("stop"),
                                                 voiceKey: "\(staff)-\(voice)"))

                case "backup":
                    cursor = max(0, cursor - (el.child("duration")?.number ?? 0) / divisions)
                case "forward":
                    cursor += (el.child("duration")?.number ?? 0) / divisions
                    measure.length = max(measure.length, cursor)

                case "barline":
                    if let r = el.child("repeat") {
                        if r.attributes["direction"] == "forward" { measure.repeatForward = true }
                        if r.attributes["direction"] == "backward" {
                            measure.repeatBackward = true
                            if let t = r.attributes["times"].flatMap({ Int($0) }), t >= 1 { measure.repeatTimes = t }
                        }
                    }
                    if let ending = el.child("ending") {
                        switch ending.attributes["type"] {
                        case "start":
                            let numbers = (ending.attributes["number"] ?? "1")
                                .split(whereSeparator: { $0 == "," || $0 == " " })
                                .compactMap { Int($0) }
                            measure.endingStart = numbers.isEmpty ? [1] : numbers
                        case "stop", "discontinue":
                            measure.endingStop = true
                        default: break
                        }
                    }

                default:
                    break
                }
            }

            if part.tempo == nil,
               let t = m.first(where: { $0.name == "sound" && $0.attributes["tempo"] != nil })?
                   .attributes["tempo"].flatMap({ Double($0) }), t > 0 {
                part.tempo = t
            }
            measure.nominalLength = timeLength
            part.measures.append(measure)
        }
        return part
    }

    private static func midiNumber(_ pitch: XMLTree) -> Int? {
        let steps: [String: Int] = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11]
        guard let step = pitch.child("step")?.text.flatMap({ steps[$0.uppercased()] }),
              let octave = pitch.child("octave")?.number else { return nil }
        let alter = Int((pitch.child("alter")?.number ?? 0).rounded())
        return (Int(octave) + 1) * 12 + step + alter
    }

    // MARK: - 反复记号展开

    /// 返回小节下标的演奏顺序
    static func playOrder(_ measures: [Measure]) -> [Int] {
        let n = measures.count
        // 每个小节属于哪个房子（第几遍才弹）
        var endingOf = [[Int]?](repeating: nil, count: n)
        var current: [Int]?
        for i in 0..<n {
            if let numbers = measures[i].endingStart { current = numbers }
            endingOf[i] = current
            if measures[i].endingStop { current = nil }
        }

        var order: [Int] = []
        var repeatStart = 0
        var pass = 1
        var i = 0
        while i < n && order.count < n * 16 {
            let m = measures[i]
            if m.repeatForward && i != repeatStart {
                repeatStart = i
                pass = 1
            }
            if let ending = endingOf[i], !ending.contains(pass) {
                i += 1
                continue
            }
            order.append(i)
            if m.repeatBackward && pass < m.repeatTimes {
                pass += 1
                i = repeatStart
                continue
            }
            if m.repeatBackward || (endingOf[i] != nil && (i + 1 == n || endingOf[i + 1] == nil)) {
                // 一段反复结束
                pass = 1
                repeatStart = i + 1
            }
            i += 1
        }
        return order
    }

    // MARK: - 连音线

    /// 被连音线连起来的音只算一个音（只有第一次起音）
    static func mergeTies(_ notes: [RawNote]) -> [RawNote] {
        var out: [RawNote] = []
        var open: [String: Int] = [:]      // 声部 + 音高 → out 中等待续接的音
        for n in notes.enumerated().sorted(by: { ($0.element.beat, $0.offset) < ($1.element.beat, $1.offset) }).map(\.element) {
            let key = "\(n.voiceKey)-\(n.midi)"
            if n.tieStop, let i = open[key] {
                out[i].duration = max(out[i].duration, n.beat + n.duration - out[i].beat)
                if !n.tieStart { open[key] = nil }
                continue
            }
            out.append(n)
            if n.tieStart { open[key] = out.count - 1 } else { open[key] = nil }
        }
        return out
    }
}

// MARK: - 极简 XML 树

final class XMLTree {
    let name: String
    let attributes: [String: String]
    fileprivate(set) var children: [XMLTree] = []
    fileprivate var buffer = ""

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    var text: String? {
        let t = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
    var number: Double? { text.flatMap { Double($0) } }

    func child(_ name: String) -> XMLTree? { children.first { $0.name == name } }
    func elements(_ name: String) -> [XMLTree] { children.filter { $0.name == name } }

    /// 深度优先找第一个满足条件的后代
    func first(where predicate: (XMLTree) -> Bool) -> XMLTree? {
        for c in children {
            if predicate(c) { return c }
            if let found = c.first(where: predicate) { return found }
        }
        return nil
    }

    static func parse(_ data: Data) -> XMLTree? {
        let builder = Builder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        // MusicXML 常带 DOCTYPE，不去联网取 DTD
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else { return nil }
        return builder.root
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: XMLTree?
        var stack: [XMLTree] = []

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            let node = XMLTree(name: elementName, attributes: attributeDict)
            if let parent = stack.last { parent.children.append(node) } else { root = node }
            stack.append(node)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            stack.removeLast()
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.buffer += string
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
