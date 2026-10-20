import Foundation

/// 过滤"余音回声"：刚弹过的音还在响的时候，它不该被当成下一个音符的弹奏。
///
/// - 弹过的音（不管对错）记入 echoes，直到声音真正散掉（音量持续很低）才清空。
/// - 余音未散期间，只接受"敲击"事件（能量突然上升）；只是音高变了的事件一律忽略。
/// - 敲击事件如果和刚弹过的是同一个音，只有在"下一步正好需要这个音"并且离上次足够久时才接受
///   （这样《小星星》里连续两个 C 能识别，而长音余音的起伏不会被当成重弹）。
struct EchoFilter {
    /// 低于这个音量算"声音已经散了"
    var silenceRMS: Float = 0.004
    /// 连续多少帧（每帧约 11.6 ms）低于 silenceRMS 才算散了
    var silenceFrames = 8
    /// 同一个音再次敲击，离上次至少要隔多久（秒）
    var minRepeatGap: Double = 0.2

    private var echoes: [Int: Double] = [:]   // 音高 → 上次被接受的起音时刻
    private var quietFrames = 0

    var isRinging: Bool { !echoes.isEmpty }

    mutating func reset() {
        echoes.removeAll()
        quietFrames = 0
    }

    /// 每一帧都要喂进来，用来判断余音什么时候散
    mutating func observe(_ frame: AnalysisFrame) {
        if frame.rms < silenceRMS {
            quietFrames += 1
            if quietFrames >= silenceFrames { echoes.removeAll() }
        } else {
            quietFrames = 0
        }
    }

    /// expected：当前这一步需要的音高
    func allows(_ event: NoteEvent, expected: [Int]) -> Bool {
        guard let played = event.midi else { return false }
        guard isRinging else { return true }
        guard event.isAttack else { return false }
        if let last = echoes[played] {
            return expected.contains(played) && event.start - last >= minRepeatGap
        }
        return true
    }

    /// 事件被采纳（判定过对错）之后调用
    mutating func accept(_ event: NoteEvent) {
        guard let played = event.midi else { return }
        echoes[played] = event.start
    }
}
