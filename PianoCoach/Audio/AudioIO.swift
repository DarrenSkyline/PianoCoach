import AVFoundation

/// 封装 AVAudioEngine：麦克风采集。
///
/// 时钟约定：所有时间都用"采集时钟"（秒）——以第一块麦克风数据的主机时间为 0 点。
/// `now` 给出此刻的采集时钟时间，AudioAnalyzer 输出的帧时间用的是同一个时钟。
final class AudioIO {
    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "pianocoach.analysis", qos: .userInitiated)

    private var analyzer: AudioAnalyzer?
    private let lock = NSLock()
    private var baseSeconds: Double?
    private var running = false

    private(set) var sampleRate: Double = 44100

    /// 在分析队列上回调（不是主线程）
    var onFrames: (([AnalysisFrame]) -> Void)?

    var hasClock: Bool {
        lock.lock(); defer { lock.unlock() }
        return baseSeconds != nil
    }

    /// 此刻的采集时钟时间；时钟尚未建立时返回 nil
    var now: Double? {
        lock.lock(); defer { lock.unlock() }
        guard let base = baseSeconds else { return nil }
        return AudioIO.hostSeconds() - base
    }

    private static func hostSeconds() -> Double {
        AVAudioTime.seconds(forHostTime: mach_absolute_time())
    }


    // MARK: 启动 / 停止

    func start() throws {
        guard !running else { return }
        let session = AVAudioSession.sharedInstance()
        // measurement 模式关闭自动增益/回声消除等，更适合分析音高
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker])
        try session.setPreferredIOBufferDuration(0.005)
        try session.setActive(true)

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            throw NSError(domain: "AudioIO", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "无法读取麦克风格式"])
        }
        sampleRate = format.sampleRate
        analyzer = AudioAnalyzer(sampleRate: sampleRate)
        lock.lock(); baseSeconds = nil; lock.unlock()

        if let playFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) {
            engine.connect(engine.mainMixerNode, to: engine.outputNode, format: playFormat)
        }

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, when in
            self?.handle(buffer: buffer, when: when)
        }

        engine.prepare()
        try engine.start()
        running = true
    }

    func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: 麦克风回调

    private func handle(buffer: AVAudioPCMBuffer, when: AVAudioTime) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: channel, count: count))

        lock.lock()
        if baseSeconds == nil {
            // 第一块数据的起点时间 = 0 点
            let host = when.isHostTimeValid
                ? AVAudioTime.seconds(forHostTime: when.hostTime)
                : AudioIO.hostSeconds() - Double(count) / sampleRate
            baseSeconds = host
        }
        lock.unlock()

        queue.async { [weak self] in
            guard let self = self, let analyzer = self.analyzer else { return }
            let frames = analyzer.process(samples)
            if !frames.isEmpty { self.onFrames?(frames) }
        }
    }
}
