import Foundation

enum Hand: String, CaseIterable, Identifiable {
    case right, left
    var id: String { rawValue }
    var title: String { self == .right ? "右手" : "左手" }
}

/// 谱面上的一个音符（只含音高、位置、时值；不保存任何出版物图像）
struct ScoreNote: Identifiable, Equatable {
    let id: Int
    let midi: Int          // 60 = 中央 C
    let beat: Double       // 从曲子开头起算的拍数（以四分音符为一拍）
    let duration: Double   // 时值（拍）
    let hand: Hand
}

/// 构建曲谱用的片段：音符或休止符
struct Item {
    let midi: Int?
    let duration: Double
    static func n(_ midi: Int, _ duration: Double) -> Item { Item(midi: midi, duration: duration) }
    static func rest(_ duration: Double) -> Item { Item(midi: nil, duration: duration) }
}

struct Score: Identifiable {
    let id = UUID()
    let title: String
    let defaultBPM: Double
    /// 每个小节的起始拍，第一个是 0。弱起小节、中途换拍号时各小节长度可以不同
    let barStarts: [Double]
    /// 曲子结束的拍数（最后一个小节的结尾）
    let endBeat: Double
    /// 调号：正数 = 升号个数，负数 = 降号个数
    let keyFifths: Int
    let notes: [ScoreNote]

    init(title: String, defaultBPM: Double, barStarts: [Double], endBeat: Double,
         keyFifths: Int = 0, notes: [ScoreNote]) {
        self.title = title
        self.defaultBPM = defaultBPM
        self.barStarts = barStarts.isEmpty ? [0] : barStarts
        self.endBeat = max(endBeat, notes.map { $0.beat + $0.duration }.max() ?? 0)
        self.keyFifths = keyFifths
        self.notes = notes
    }

    var totalBeats: Double { endBeat }
    var barCount: Int { barStarts.count }

    /// beat 所在小节的下标（从 0 开始）
    func barIndex(at beat: Double) -> Int {
        var lo = 0, hi = barStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if barStarts[mid] <= beat + 1e-9 { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    func barLength(_ index: Int) -> Double {
        let end = index + 1 < barStarts.count ? barStarts[index + 1] : endBeat
        return max(1e-9, end - barStarts[index])
    }

    func notes(for hand: Hand) -> [ScoreNote] { notes.filter { $0.hand == hand } }

    /// 按起音时刻分组：同一时刻的几个音（和弦）是一步
    func steps(for hand: Hand) -> [[ScoreNote]] {
        var steps: [[ScoreNote]] = []
        for note in notes(for: hand).sorted(by: { ($0.beat, $0.midi) < ($1.beat, $1.midi) }) {
            if let last = steps.last?.first, abs(last.beat - note.beat) < 1e-6 {
                steps[steps.count - 1].append(note)
            } else {
                steps.append([note])
            }
        }
        return steps
    }

    static func make(title: String, bpm: Double, beatsPerBar: Int = 4,
                     right: [Item], left: [Item]) -> Score {
        var notes: [ScoreNote] = []
        var nextID = 0
        var total = 0.0
        for (items, hand) in [(right, Hand.right), (left, Hand.left)] {
            var beat = 0.0
            for item in items {
                if let m = item.midi {
                    notes.append(ScoreNote(id: nextID, midi: m, beat: beat,
                                           duration: item.duration, hand: hand))
                    nextID += 1
                }
                beat += item.duration
            }
            total = max(total, beat)
        }
        let barLength = Double(beatsPerBar)
        let bars = max(1, Int(ceil(total / barLength - 1e-9)))
        return Score(title: title, defaultBPM: bpm,
                     barStarts: (0..<bars).map { Double($0) * barLength },
                     endBeat: Double(bars) * barLength, notes: notes)
    }
}

/// 音名工具
enum NoteName {
    private static let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
    static func name(_ midi: Int) -> String {
        let pc = ((midi % 12) + 12) % 12
        return "\(names[pc])\(midi / 12 - 1)"
    }
}

/// 五线谱位置：diatonic = 八度*7 + 音级（C=0…B=6），C4 = 28
struct StaffPosition {
    let diatonic: Int
    /// 需要画的变音记号："♯"、"♭" 或 nil
    let accidental: String?

    /// preferFlats：降号调里把黑键写成降号（如 B♭ 而不是 A♯）
    static func make(midi: Int, preferFlats: Bool = false) -> StaffPosition {
        let pc = ((midi % 12) + 12) % 12
        let octave = midi / 12 - 1
        let black = [false, true, false, true, false, false, true, false, true, false, true, false]
        if preferFlats && black[pc] {
            // 写成上方白键的降号
            let upper = [0, 1, 1, 2, 2, 3, 4, 4, 5, 5, 6, 6]
            return StaffPosition(diatonic: octave * 7 + upper[pc], accidental: "♭")
        }
        let steps = [0, 0, 1, 1, 2, 3, 3, 4, 4, 5, 5, 6]
        return StaffPosition(diatonic: octave * 7 + steps[pc], accidental: black[pc] ? "♯" : nil)
    }

    /// 高音谱表最下线 E4，低音谱表最下线 G2
    static let trebleBottom = 30
    static let bassBottom = 18
}
