import Foundation
import Testing
@testable import PianoCoach

/// 合成音频帧：每个音指数衰减，总音量是各音之和，音高取最响的那个。
/// 场景与做法和 PracticeSession.handle 保持一致：追踪器每一帧都喂，事件先过 EchoFilter。
private struct Simulation {
    static let sampleRate = 44100.0
    static let dt = Double(AudioAnalyzer.hop) / sampleRate

    var notes: [(time: Double, midi: Int)]
    var duration: Double
    var tau = 1.8          // 余音衰减时间常数（秒）
    var peak: Float = 0.15

    func frames() -> [AnalysisFrame] {
        let count = Int(duration / Self.dt)
        return (0..<count).map { i in
            let t = Double(i + 1) * Self.dt
            var env: [Int: Float] = [:]
            for n in notes where t >= n.time {
                env[n.midi, default: 0] += peak * Float(exp(-(t - n.time) / tau))
            }
            let rms = env.values.reduce(0, +) + 0.0006
            let transient = notes.contains { t - $0.time >= 0 && t - $0.time < 0.025 }
            let loudest = env.max { $0.value < $1.value }?.key
            let midi = (rms > 0.003 && !transient) ? loudest : nil
            return AnalysisFrame(time: t, rms: rms, midi: midi, clarity: midi == nil ? 0 : 0.95)
        }
    }

    /// 返回每个被接受的事件及其对错，规则同 PracticeSession：弹对才前进
    func run(steps: [Int]) -> [(midi: Int, correct: Bool)] {
        let tracker = NoteTracker(sampleRate: Self.sampleRate)
        var filter = EchoFilter()
        var index = 0
        var log: [(Int, Bool)] = []
        for frame in frames() where index < steps.count {
            filter.observe(frame)
            for ev in tracker.process(frame) {
                guard filter.allows(ev, expected: [steps[index]]) else { continue }
                filter.accept(ev)
                let ok = ev.midi == steps[index]
                log.append((ev.midi!, ok))
                if ok { index += 1 }
                break
            }
        }
        return log.map { (midi: $0.0, correct: $0.1) }
    }
}

struct EchoFilterTests {
    let C = 60, D = 62, E = 64, G = 67

    /// 用户报告的问题：按住 C 很久，余音衰减后不能被当成下一个音符的弹奏
    @Test func heldNoteDoesNotBecomeNextNote() {
        let log = Simulation(notes: [(0.5, C)], duration: 9.5).run(steps: [C, D])
        #expect(log.count == 1)
        #expect(log.first?.midi == C && log.first?.correct == true)
    }

    @Test func nextNoteIsHeardWhileTheLastOneStillRings() {
        // 按住 C 5 秒（余音还没散）再弹 D
        let log = Simulation(notes: [(0.5, C), (5.5, D)], duration: 8).run(steps: [C, D])
        #expect(log.map(\.midi) == [C, D])
        #expect(log.allSatisfy(\.correct))
    }

    @Test func legatoSequence() {
        let log = Simulation(notes: [(0.5, C), (1.2, D), (1.9, E)], duration: 5).run(steps: [C, D, E])
        #expect(log.map(\.midi) == [C, D, E])
        #expect(log.allSatisfy(\.correct))
    }

    @Test func repeatedSameNoteIsRecognised() {
        let log = Simulation(notes: [(0.5, C), (1.4, C)], duration: 4).run(steps: [C, C])
        #expect(log.map(\.midi) == [C, C])
        #expect(log.allSatisfy(\.correct))
    }

    @Test func wrongNoteThenCorrection() {
        let log = Simulation(notes: [(0.5, C), (1.3, E), (2.2, D)], duration: 5).run(steps: [C, D])
        #expect(log.map(\.midi) == [C, E, D])
        #expect(log.map(\.correct) == [true, false, true])
    }

    // MARK: 过滤器本身

    private func attack(_ midi: Int, at t: Double) -> NoteEvent { NoteEvent(start: t, midi: midi, isAttack: true) }
    private func pitchChange(_ midi: Int, at t: Double) -> NoteEvent { NoteEvent(start: t, midi: midi, isAttack: false) }
    private func quiet(_ t: Double) -> AnalysisFrame { AnalysisFrame(time: t, rms: 0.001, midi: nil, clarity: 0) }

    @Test func everythingPassesWhenNothingIsRinging() {
        let f = EchoFilter()
        #expect(f.allows(attack(C, at: 1), expected: [D]))
        #expect(f.allows(pitchChange(C, at: 1), expected: [D]))
    }

    @Test func onlyAttacksPassWhileRinging() {
        var f = EchoFilter()
        f.accept(attack(C, at: 1))
        #expect(!f.allows(pitchChange(D, at: 2), expected: [D]))
        #expect(f.allows(attack(D, at: 2), expected: [D]))
    }

    @Test func sameNoteNeedsAnAttackThatIsExpectedAndNotTooSoon() {
        var f = EchoFilter()
        f.accept(attack(C, at: 1))
        #expect(!f.allows(attack(C, at: 3), expected: [G]))      // 下一步不要 C：当作余音起伏
        #expect(!f.allows(attack(C, at: 1.1), expected: [C]))    // 太快
        #expect(f.allows(attack(C, at: 1.5), expected: [C]))
        #expect(!f.allows(pitchChange(C, at: 3), expected: [C])) // 不是敲击
    }

    @Test func echoesClearOnceTheSoundHasDied() {
        var f = EchoFilter()
        f.accept(attack(C, at: 1))
        #expect(f.isRinging)
        for i in 0..<f.silenceFrames { f.observe(quiet(2 + Double(i) * 0.0116)) }
        #expect(!f.isRinging)
        #expect(f.allows(pitchChange(D, at: 3), expected: [D]))
    }
}
