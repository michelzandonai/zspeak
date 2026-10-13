import AVFoundation

/// Isola o I/O para testar reconexões Bluetooth sem depender de um microfone físico.
protocol AudioCaptureEngine: AnyObject {
    var isRunning: Bool { get }
    var inputFormat: AVAudioFormat { get }
    var configurationChangeSource: AnyObject { get }
    func setVoiceProcessingEnabled(_ enabled: Bool) throws
    func installInputTap(_ block: @escaping AVAudioNodeTapBlock)
    func removeInputTap()
    func prepare()
    func start() throws
    func stop()
}

extension AVAudioEngine: AudioCaptureEngine {
    var inputFormat: AVAudioFormat { inputNode.outputFormat(forBus: 0) }
    var configurationChangeSource: AnyObject { self }

    func setVoiceProcessingEnabled(_ enabled: Bool) throws {
        try inputNode.setVoiceProcessingEnabled(enabled)
    }

    func installInputTap(_ block: @escaping AVAudioNodeTapBlock) {
        inputNode.installTap(onBus: 0, bufferSize: 512, format: nil, block: block)
    }

    func removeInputTap() {
        inputNode.removeTap(onBus: 0)
    }
}
