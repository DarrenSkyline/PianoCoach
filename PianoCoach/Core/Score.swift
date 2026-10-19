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
    let beat: Double       // 从曲子开头起算的拍数
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
    let beatsPerBar: Int
    let notes: [ScoreNote]

    var totalBeats: Double { notes.map { $0.beat + $0.duration }.max() ?? 0 }
    var barCount: Int { max(1, Int(ceil(totalBeats / Double(beatsPerBar) - 1e-9))) }

    func notes(for hand: Hand) -> [ScoreNote] { notes.filter { $0.hand == hand } }

    static func make(title: String, bpm: Double, beatsPerBar: Int = 4,
                     right: [Item], left: [Item]) -> Score {
        var notes: [ScoreNote] = []
        var nextID = 0
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
        }
        return Score(title: title, defaultBPM: bpm, beatsPerBar: beatsPerBar, notes: notes)
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
    let sharp: Bool

    static func make(midi: Int) -> StaffPosition {
        let steps = [0, 0, 1, 1, 2, 3, 3, 4, 4, 5, 5, 6]
        let sharps = [false, true, false, true, false, false, true, false, true, false, true, false]
        let pc = ((midi % 12) + 12) % 12
        return StaffPosition(diatonic: (midi / 12 - 1) * 7 + steps[pc], sharp: sharps[pc])
    }

    /// 高音谱表最下线 E4，低音谱表最下线 G2
    static let trebleBottom = 30
    static let bassBottom = 18
}
