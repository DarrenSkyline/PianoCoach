import Foundation

/// 一个被识别出来的"弹奏事件"
struct NoteEvent {
    let start: Double   // 起音时刻（秒，采集时钟）
    let midi: Int?      // 多数投票得到的音高；没有稳定音高则 nil
}

/// 把逐帧结果变成"弹了一个音"的事件。
/// 两种起音来源：1) 能量突然上升；2) 音高稳定地变成另一个音（新音叠在旧音余音上时）。
/// 与 Prototype/prototype.py 的 Tracker 对应。
final class NoteTracker {
    struct Config {
        var onsetRatio: Float = 1.5
        var onsetFloor: Float = 0.006
        var refractory: Double = 0.09
        var voteDelay: Double = 0.075      // 起音后多久开始采信音高
        var observe: Double = 0.22         // 观察时长
        var minVotes = 3
        var pitchRun = 3                   // 连续几帧新音高才算"音高变化起音"
        var pitchOnsetLag: Double = 0.035
    }

    private struct Pending {
        var start: Double
        var votes: [Int]
    }

    private let cfg: Config
    private let halfHop: Double
    private var recentRMS: [Float] = []
    private var lastOnset = -1e9
    private var pending: Pending?
    private var sounding: Int?
    private var runMidi: Int?
    private var runCount = 0
    private var runFirstTime = 0.0

    init(sampleRate: Double, config: Config = Config()) {
        self.cfg = config
        self.halfHop = Double(AudioAnalyzer.hop) / 2 / sampleRate
    }

    /// 丢弃当前所有待处理状态（在等待静音期间调用，防止余音触发新事件）
    func reset() {
        pending = nil
        sounding = nil
        runMidi = nil
        runCount = 0
        recentRMS.removeAll()
        lastOnset = -1e9
    }

    func process(_ fr: AnalysisFrame) -> [NoteEvent] {
        var out: [NoteEvent] = []

        var isOnset = false
        if recentRMS.count >= 4, let prev = recentRMS.suffix(4).min() {
            isOnset = fr.rms > cfg.onsetFloor
                && fr.rms > cfg.onsetRatio * max(prev, 1e-4)
                && fr.time - lastOnset > cfg.refractory
        }
        recentRMS.append(fr.rms)
        if recentRMS.count > 16 { recentRMS.removeFirst() }

        // 连续音高跟踪
        if let m = fr.midi {
            if m == runMidi {
                runCount += 1
            } else {
                runMidi = m
                runCount = 1
                runFirstTime = fr.time
            }
        } else {
            runMidi = nil
            runCount = 0
        }

        if isOnset {
            if pending != nil { out.append(finish()) }
            lastOnset = fr.time
            pending = Pending(start: fr.time - halfHop, votes: [])
            runMidi = nil
            runCount = 0
            return out
        }

        if runCount >= cfg.pitchRun, let rm = runMidi, rm != sounding,
           fr.time - lastOnset > 0.15 {
            if pending != nil { out.append(finish()) }
            lastOnset = fr.time
            pending = Pending(start: runFirstTime - cfg.pitchOnsetLag,
                              votes: Array(repeating: rm, count: runCount))
            runMidi = nil
            runCount = 0
            return out
        }

        if var p = pending {
            if fr.time - p.start >= cfg.voteDelay, let m = fr.midi {
                p.votes.append(m)
            }
            pending = p
            if fr.time - p.start >= cfg.observe { out.append(finish()) }
        }
        return out
    }

    private func finish() -> NoteEvent {
        let p = pending!
        pending = nil
        var midi: Int? = nil
        if p.votes.count >= cfg.minVotes {
            var counts: [Int: Int] = [:]
            for v in p.votes { counts[v, default: 0] += 1 }
            midi = counts.max { $0.value < $1.value }?.key
        }
        if let m = midi { sounding = m }
        return NoteEvent(start: p.start, midi: midi)
    }
}
