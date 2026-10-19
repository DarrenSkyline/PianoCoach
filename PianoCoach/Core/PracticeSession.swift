import Foundation
import AVFoundation
import Combine
import SwiftUI
import UIKit

struct PracticeSummary {
    let total: Int
    let correct: Int
    let wrong: Int
    let missed: Int
    /// 音高准确率
    var pitchAccuracy: Double { total == 0 ? 0 : Double(correct) / Double(total) }
    /// 出错最多的小节（从 1 开始），可能有多个
    let worstBars: [Int]
}

@MainActor
final class PracticeSession: ObservableObject {
    enum Phase { case idle, playing, finished }

    // 设置
    @Published var score: Score = SampleScores.twinkle {
        didSet { if oldValue.id != score.id { bpm = score.defaultBPM; resetResults() } }
    }
    @Published var hand: Hand = .right { didSet { resetResults() } }
    @Published var bpm: Double = SampleScores.twinkle.defaultBPM
    @Published var calibration: Double = 0

    // 状态
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var results: [Int: NoteResult] = [:]   // key = ScoreNote.id
    /// 当前待弹音符在 activeNotes 中的下标，-1 表示未开始
    @Published private(set) var currentIndex: Int = -1
    @Published private(set) var liveNote: String = "—"
    @Published private(set) var level: Float = 0
    @Published private(set) var summary: PracticeSummary?
    @Published var micDenied = false
    @Published var errorMessage: String?

    private let io = AudioIO()
    private var tracker: NoteTracker?
    private var activeNotes: [ScoreNote] = []
    private var lastVoicedTime = -1e9
    /// 弹完一个音后等待静音，防止余音触发下一个识别
    private var waitingForSilence = false
    private var silenceFrameCount = 0
    private let silenceFramesRequired = 6   // ≈ 0.13 秒静音
    /// 当前音符已经记录过错误（防止重复写入）
    private var currentNoteErrorRecorded = false

    var activeHandNotes: [ScoreNote] { score.notes(for: hand) }

    /// 当前待弹的音符
    var currentNote: ScoreNote? {
        guard currentIndex >= 0, currentIndex < activeNotes.count else { return nil }
        return activeNotes[currentIndex]
    }

    init() {
        io.onFrames = { [weak self] frames in
            Task { @MainActor [weak self] in self?.handle(frames) }
        }
    }

    // MARK: 开始 / 停止

    func start() {
        guard phase == .idle || phase == .finished else { return }
        resetResults()
        Task { await begin() }
    }

    func stop() {
        guard phase == .playing else { return }
        finish(aborted: true)
    }

    func reset() {
        if phase == .finished { phase = .idle }
        resetResults()
    }

    private func resetResults() {
        guard phase != .playing else { return }
        results = [:]
        summary = nil
        currentIndex = -1
        liveNote = "—"
        currentNoteErrorRecorded = false
        if phase == .finished { phase = .idle }
    }

    // MARK: 启动流程

    private func begin() async {
        let granted = await Self.requestMicrophonePermission()
        guard granted else { micDenied = true; return }

        do { try io.start() } catch {
            errorMessage = "无法启动音频：\(error.localizedDescription)"
            return
        }
        for _ in 0..<40 where !io.hasClock {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        guard io.hasClock else {
            errorMessage = "没有收到麦克风数据，请检查权限或是否被其他 App 占用。"
            io.stop()
            return
        }

        activeNotes = activeHandNotes
        guard !activeNotes.isEmpty else { io.stop(); return }

        tracker = NoteTracker(sampleRate: io.sampleRate)
        lastVoicedTime = -1e9
        waitingForSilence = false
        silenceFrameCount = 0
        currentIndex = 0
        currentNoteErrorRecorded = false
        phase = .playing
        UIApplication.shared.isIdleTimerDisabled = true
    }

    // MARK: 音频帧处理

    private func handle(_ frames: [AnalysisFrame]) {
        guard phase == .playing, let tracker = tracker else { return }

        for fr in frames {
            // 音量表 & 实时音名
            level = max(level * 0.85, min(1, fr.rms * 10))
            if let m = fr.midi {
                liveNote = NoteName.name(m)
                lastVoicedTime = fr.time
            } else if fr.time - lastVoicedTime > 0.5 {
                liveNote = "—"
                level = max(0, level * 0.92)
            }

            // 等待静音：识别完一个音后，必须等声音平息才处理下一个
            if waitingForSilence {
                if fr.rms < 0.008 {
                    silenceFrameCount += 1
                    if silenceFrameCount >= silenceFramesRequired {
                        waitingForSilence = false
                        silenceFrameCount = 0
                        tracker.reset()
                    }
                } else {
                    silenceFrameCount = 0
                }
                continue
            }

            // 正常处理，每次只取第一个有效事件
            for ev in tracker.process(fr) {
                guard ev.midi != nil else { continue }
                handleEvent(ev)
                waitingForSilence = true
                silenceFrameCount = 0
                break
            }
        }
    }

    /// 将弹奏事件与当前待弹音符比较：
    /// - 弹对 → 标记正确，前进到下一个音符
    /// - 弹错 → 记录一次错误（之后再弹错不重复记录），停在当前音符等待弹对
    private func handleEvent(_ ev: NoteEvent) {
        guard let played = ev.midi else { return }
        guard currentIndex < activeNotes.count else { return }

        let note = activeNotes[currentIndex]

        if played == note.midi {
            // 弹对了：若之前已记录错误则保留 .wrong，否则标记 .correct
            if results[note.id]?.state != .wrong {
                var result = NoteResult()
                result.playedMidi = played
                result.state = .correct
                results[note.id] = result
            }
            // 前进到下一个音符
            currentNoteErrorRecorded = false
            let next = currentIndex + 1
            if next >= activeNotes.count {
                finish(aborted: false)
            } else {
                currentIndex = next
            }
        } else {
            // 弹错了：只在第一次记录错误，之后停在此音符继续等
            if !currentNoteErrorRecorded {
                var result = NoteResult()
                result.playedMidi = played
                result.state = .wrong
                let diff = played - note.midi
                result.detail = diff % 12 == 0 ? "八度不对" : (diff > 0 ? "偏高" : "偏低")
                results[note.id] = result
                currentNoteErrorRecorded = true
            }
            // 不前进，等用户重新弹
        }
    }

    private func finish(aborted: Bool) {
        UIApplication.shared.isIdleTimerDisabled = false
        io.stop()

        if aborted {
            phase = .idle
            summary = nil
        } else {
            summary = makeSummary()
            phase = .finished
        }
    }

    private func makeSummary() -> PracticeSummary {
        var correct = 0, wrong = 0, missed = 0
        var badPerBar: [Int: Int] = [:]
        for note in activeNotes {
            let r = results[note.id] ?? NoteResult()
            switch r.state {
            case .correct:          correct += 1
            case .wrong:            wrong += 1
            case .missed, .pending: missed += 1
            case .timing:           correct += 1
            }
            if r.state == .wrong || r.state == .missed || r.state == .pending {
                badPerBar[Int(note.beat / Double(score.beatsPerBar)) + 1, default: 0] += 1
            }
        }
        let worst = badPerBar.values.max() ?? 0
        let bars = worst > 0 ? badPerBar.filter { $0.value == worst }.keys.sorted() : []
        return PracticeSummary(total: activeNotes.count, correct: correct,
                               wrong: wrong, missed: missed, worstBars: bars)
    }

    // MARK: 麦克风权限

    private static func requestMicrophonePermission() async -> Bool {
        if #available(iOS 17.0, *) {
            return await AVAudioApplication.requestRecordPermission()
        } else {
            return await withCheckedContinuation { cont in
                AVAudioSession.sharedInstance().requestRecordPermission { cont.resume(returning: $0) }
            }
        }
    }
}
