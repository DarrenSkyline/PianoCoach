import Foundation
import Accelerate

/// 一帧分析结果（约每 11ms 一帧）
struct AnalysisFrame {
    let time: Double      // 帧结束时刻（秒，自采集开始起算）
    let rms: Float        // 最近一个 hop 的 RMS
    let midi: Int?        // 检测到的音高；没有则 nil
    let clarity: Double
}

/// 把连续的麦克风采样切成 hop 块，逐帧输出 RMS 与音高。
/// 与 Prototype/prototype.py 的 Analyzer 对应。
final class AudioAnalyzer {
    static let hop = 512
    static let bufferSize = 2048

    let sampleRate: Double
    var rmsFloor: Float = 0.003
    var minClarity: Double = 0.8

    private let detector: YINPitchDetector
    private var ring = [Float](repeating: 0, count: AudioAnalyzer.bufferSize)
    private var leftover: [Float] = []
    private var filled = 0
    private(set) var totalSamples = 0

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        self.detector = YINPitchDetector(sampleRate: sampleRate)
    }

    func process(_ samples: [Float]) -> [AnalysisFrame] {
        let hop = AudioAnalyzer.hop
        leftover.append(contentsOf: samples)
        var frames: [AnalysisFrame] = []
        var offset = 0

        while leftover.count - offset >= hop {
            let block = Array(leftover[offset..<(offset + hop)])
            offset += hop
            ring.removeFirst(hop)
            ring.append(contentsOf: block)
            totalSamples += hop
            filled = min(AudioAnalyzer.bufferSize, filled + hop)

            var rms: Float = 0
            block.withUnsafeBufferPointer { vDSP_rmsqv($0.baseAddress!, 1, &rms, vDSP_Length(hop)) }

            var midi: Int? = nil
            var clarity = 0.0
            if filled >= AudioAnalyzer.bufferSize && rms > rmsFloor {
                let estimate = ring.withUnsafeBufferPointer {
                    detector.detect(samples: $0.baseAddress!, count: $0.count)
                }
                if let est = estimate, est.clarity >= minClarity {
                    clarity = est.clarity
                    midi = YINPitchDetector.midiNumber(forFrequency: est.frequency)
                }
            }
            frames.append(AnalysisFrame(time: Double(totalSamples) / sampleRate,
                                        rms: rms, midi: midi, clarity: clarity))
        }
        leftover.removeFirst(offset)
        return frames
    }
}
