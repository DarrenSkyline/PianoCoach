import AVFoundation

/// 预先渲染好的节拍声（倒数 + 可选的全程节拍），采样级精确。
enum ClickTrack {

    /// - Parameters:
    ///   - countInBeats: 倒数拍数（通常等于每小节拍数）
    ///   - playBeats: 正式演奏的拍数；`clickDuringPlay` 为 false 时不渲染这部分
    static func render(sampleRate: Double,
                       bpm: Double,
                       countInBeats: Int,
                       beatsPerBar: Int,
                       playBeats: Int,
                       clickDuringPlay: Bool) -> AVAudioPCMBuffer? {
        let beatSeconds = 60.0 / bpm
        let totalBeats = countInBeats + (clickDuringPlay ? playBeats : 0)
        let totalFrames = Int((Double(totalBeats) * beatSeconds + 0.2) * sampleRate)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(totalFrames)),
              let data = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(totalFrames)
        for i in 0..<totalFrames { data[i] = 0 }

        let clickLength = Int(0.04 * sampleRate)
        for beat in 0..<totalBeats {
            let isAccent = beat < countInBeats ? (beat == 0) : ((beat - countInBeats) % beatsPerBar == 0)
            let freq = isAccent ? 1600.0 : 1100.0
            let start = Int(Double(beat) * beatSeconds * sampleRate)
            for k in 0..<clickLength where start + k < totalFrames {
                let t = Double(k) / sampleRate
                let envelope = exp(-t * 90)
                data[start + k] += Float(0.6 * envelope * sin(2 * .pi * freq * t))
            }
        }
        return buffer
    }
}
