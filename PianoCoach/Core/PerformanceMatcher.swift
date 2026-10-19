import Foundation

enum NoteState {
    case pending   // 还没到/还没弹
    case correct   // 音对、节奏对 → 绿
    case timing    // 音对、节奏偏差大 → 橙
    case wrong     // 弹错音 → 红
    case missed    // 没弹 → 灰
}

struct NoteResult {
    var state: NoteState = .pending
    var playedMidi: Int?
    var offset: Double?      // 秒；正数 = 弹晚了
    var detail: String = ""  // "偏高" "偏低" "八度不对" "早了" "晚了"
}

/// 把弹奏事件对照到乐谱音符上。
/// 与 Prototype/prototype.py 的 Matcher 对应。
final class PerformanceMatcher {
    let notes: [ScoreNote]
    let beatSeconds: Double
    let t0: Double                 // 第 0 拍对应的采集时钟时刻
    private(set) var results: [NoteResult]
    private let times: [Double]
    private let tolerance: [Double]

    init(notes: [ScoreNote], bpm: Double, t0: Double) {
        self.notes = notes
        self.beatSeconds = 60.0 / bpm
        self.t0 = t0
        self.results = Array(repeating: NoteResult(), count: notes.count)
        let ts = notes.map { t0 + $0.beat * 60.0 / bpm }
        self.times = ts
        var tol: [Double] = []
        for i in 0..<ts.count {
            let gapPrev = i > 0 ? ts[i] - ts[i - 1] : 9.9
            let gapNext = i + 1 < ts.count ? ts[i + 1] - ts[i] : 9.9
            tol.append(min(0.4, max(0.12, 0.45 * min(gapPrev, gapNext))))
        }
        self.tolerance = tol
    }

    /// 喂入一个弹奏事件，返回状态发生变化的音符下标
    @discardableResult
    func feed(_ ev: NoteEvent) -> [Int] {
        guard let played = ev.midi else { return [] }

        var best: Int?
        var bestKey: (Int, Double) = (Int.max, Double.greatestFiniteMagnitude)
        for i in 0..<notes.count where results[i].state == .pending {
            let dt = ev.start - times[i]
            guard abs(dt) <= tolerance[i] else { continue }
            // 优先音高相同的，其次时间最近的
            let key = (notes[i].midi == played ? 0 : 1, abs(dt))
            if key < bestKey {
                best = i
                bestKey = key
            }
        }
        guard let i = best else { return [] }   // 窗口外的声音，忽略

        let dt = ev.start - times[i]
        results[i].offset = dt
        results[i].playedMidi = played
        if played == notes[i].midi {
            if abs(dt) <= 0.6 * tolerance[i] {
                results[i].state = .correct
            } else {
                results[i].state = .timing
                results[i].detail = dt > 0 ? "晚了" : "早了"
            }
        } else {
            results[i].state = .wrong
            let diff = played - notes[i].midi
            if diff % 12 == 0 {
                results[i].detail = "八度不对"
            } else {
                results[i].detail = diff > 0 ? "偏高" : "偏低"
            }
        }
        return [i]
    }

    /// 时间已过窗口还没弹的，判为漏弹。传 .infinity 表示结算全部。
    @discardableResult
    func expire(now: Double) -> [Int] {
        var changed: [Int] = []
        for i in 0..<notes.count where results[i].state == .pending {
            if now > times[i] + tolerance[i] + 0.25 {
                results[i].state = .missed
                changed.append(i)
            }
        }
        return changed
    }
}
