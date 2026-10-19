import Foundation
import Accelerate

struct PitchEstimate {
    let frequency: Double
    /// 0...1，越接近 1 越像稳定的周期信号
    let clarity: Double
}

/// YIN 单音音高检测（de Cheveigné & Kawahara, 2002）。
/// 与 Prototype/prototype.py 中的 yin() 一一对应。
/// 非线程安全：每个实例只能在同一个队列里使用。
final class YINPitchDetector {
    let sampleRate: Double
    let windowSize: Int
    let threshold: Double
    let minFrequency: Double
    let maxFrequency: Double

    private var difference: [Double] = []
    private var cmnd: [Double] = []
    private var cumulative: [Double] = []

    init(sampleRate: Double,
         windowSize: Int = 1024,
         threshold: Double = 0.15,
         minFrequency: Double = 60,
         maxFrequency: Double = 1800) {
        self.sampleRate = sampleRate
        self.windowSize = windowSize
        self.threshold = threshold
        self.minFrequency = minFrequency
        self.maxFrequency = maxFrequency
    }

    /// 需要的最少采样数：windowSize + 最大周期
    var requiredSamples: Int { windowSize + Int(sampleRate / minFrequency) + 1 }

    func detect(samples: UnsafePointer<Float>, count: Int) -> PitchEstimate? {
        let w = windowSize
        let tauMax = min(Int(sampleRate / minFrequency), count - w)
        let tauMin = max(2, Int(sampleRate / maxFrequency))
        guard tauMax > tauMin + 2 else { return nil }

        if cumulative.count < count + 1 { cumulative = [Double](repeating: 0, count: count + 1) }
        if difference.count < tauMax + 2 {
            difference = [Double](repeating: 0, count: tauMax + 2)
            cmnd = [Double](repeating: 0, count: tauMax + 2)
        }

        // 平方的累积和（Double，避免精度损失）
        cumulative[0] = 0
        for i in 0..<count {
            let v = Double(samples[i])
            cumulative[i + 1] = cumulative[i] + v * v
        }
        let e0 = cumulative[w]

        // 差分函数 d(tau) = e0 + e(tau) - 2 * cross(tau)
        for tau in 1...tauMax {
            var cross: Float = 0
            vDSP_dotpr(samples, 1, samples + tau, 1, &cross, vDSP_Length(w))
            let eTau = cumulative[tau + w] - cumulative[tau]
            difference[tau] = max(0, e0 + eTau - 2 * Double(cross))
        }

        // 累积均值归一化差分
        cmnd[0] = 1
        var running = 0.0
        for tau in 1...tauMax {
            running += difference[tau]
            cmnd[tau] = running > 0 ? difference[tau] * Double(tau) / running : 1
        }

        // 第一个低于阈值的局部最小
        var tauEstimate = -1
        var tau = tauMin
        while tau < tauMax {
            if cmnd[tau] < threshold {
                while tau + 1 < tauMax && cmnd[tau + 1] < cmnd[tau] { tau += 1 }
                tauEstimate = tau
                break
            }
            tau += 1
        }
        guard tauEstimate > 0 else { return nil }

        // 抛物线插值，提高精度
        let a = cmnd[tauEstimate - 1]
        let b = cmnd[tauEstimate]
        let c = cmnd[tauEstimate + 1]
        let denom = a - 2 * b + c
        let shift = denom != 0 ? 0.5 * (a - c) / denom : 0
        let tauRefined = Double(tauEstimate) + shift
        guard tauRefined > 0 else { return nil }

        return PitchEstimate(frequency: sampleRate / tauRefined, clarity: 1 - b)
    }

    static func midiNumber(forFrequency f: Double) -> Int {
        Int((69 + 12 * log2(f / 440.0)).rounded())
    }
}
