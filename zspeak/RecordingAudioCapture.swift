import Foundation

/// O modo combinado mantém o pipeline de microfone e usa ScreenCaptureKit
/// apenas durante a gravação, sem deixar a saída do computador aberta em idle.
actor RecordingAudioCapture: AudioCapturing {
    nonisolated static let systemAudioEnabledKey = "captureSystemAudio"
    nonisolated static let microphoneWithSystemAudioKey = "microphoneWithSystemAudio"
    private var sessionIncludesMicrophone = true
    private var sessionIncludesSystemAudio = false
    private var sessionDeviceUID: String?
    private var sessionOnSamples: (@Sendable ([Float]) -> Void)?
    private var sessionActive = false
    private var completedSegments: [[Float]] = []
    private let includesMicrophone: @Sendable () -> Bool
    private let microphone: any TimestampedMicrophoneCapturing
    private let systemAudio: any SystemAudioCapturing
    private let includesSystemAudio: @Sendable () -> Bool
    private let hostTime: @Sendable () -> TimeInterval
    private var mixer: AudioTimelineMixer?
    private var pump: Task<Void, Never>?
    private var startInProgress = false
    private var waitingStarts: [CheckedContinuation<Void, Never>] = []
    private let liveEmitter = LiveSampleEmitter(chunkSampleCount: 4_000)
    private nonisolated let combinedMode = AtomicBool()
    private nonisolated let levelMonitor = AudioLevelMonitor()

    init(
        microphone: any TimestampedMicrophoneCapturing = AudioCapture(),
        systemAudio: any SystemAudioCapturing = SystemAudioCapture(),
        includesSystemAudio: @escaping @Sendable () -> Bool = { UserDefaults.standard.bool(forKey: RecordingAudioCapture.systemAudioEnabledKey) },
        includesMicrophone: @escaping @Sendable () -> Bool = { UserDefaults.standard.bool(forKey: RecordingAudioCapture.microphoneWithSystemAudioKey) },
        hostTime: @escaping @Sendable () -> TimeInterval = { audioHostTime() }
    ) {
        self.microphone = microphone
        self.systemAudio = systemAudio
        self.includesSystemAudio = includesSystemAudio
        self.hostTime = hostTime
        self.includesMicrophone = includesMicrophone
    }

    nonisolated func currentAudioLevel() -> Float {
        combinedMode.current ? levelMonitor.currentLevel() : microphone.currentAudioLevel()
    }

    nonisolated func isInputClipping() -> Bool {
        combinedMode.current ? levelMonitor.isClippingRecently() : microphone.isInputClipping()
    }

    func start(deviceUID: String?, onFirstSample: (@Sendable () -> Void)?, onSamples: (@Sendable ([Float]) -> Void)?) async throws {
        try await start(deviceUID: deviceUID, onFirstSample: onFirstSample, onSamples: onSamples, includesSystemAudio: includesSystemAudio())
    }

    func start(
        deviceUID: String?, onFirstSample: (@Sendable () -> Void)?,
        onSamples: (@Sendable ([Float]) -> Void)?, includesSystemAudio: Bool
    ) async throws {
        try await start(deviceUID: deviceUID, onFirstSample: onFirstSample,
                        onSamples: onSamples, includesSystemAudio: includesSystemAudio,
                        includesMicrophone: !includesSystemAudio || includesMicrophone())
    }

    func start(
        deviceUID: String?, onFirstSample: (@Sendable () -> Void)?,
        onSamples: (@Sendable ([Float]) -> Void)?, includesSystemAudio: Bool,
        includesMicrophone: Bool
    ) async throws {
        try await acquireStartSlot()
        defer { releaseStartSlot() }
        if sessionActive { _ = await stopSegment() }
        completedSegments = []
        sessionOnSamples = onSamples
        sessionActive = true
        do {
            try await startSegment(deviceUID: deviceUID, onFirstSample: onFirstSample,
                                   onSamples: onSamples, includesSystemAudio: includesSystemAudio,
                                   includesMicrophone: includesMicrophone)
        } catch {
            sessionActive = false
            throw error
        }
    }

    private func startSegment(
        deviceUID: String?, onFirstSample: (@Sendable () -> Void)?,
        onSamples: (@Sendable ([Float]) -> Void)?, includesSystemAudio: Bool,
        includesMicrophone: Bool
    ) async throws {
        try Task.checkCancellation()
        sessionIncludesSystemAudio = includesSystemAudio
        sessionDeviceUID = deviceUID
        sessionIncludesMicrophone = !includesSystemAudio || includesMicrophone
        guard includesSystemAudio else {
            combinedMode.set(false)
            try await microphone.start(deviceUID: deviceUID, onFirstSample: onFirstSample, onSamples: onSamples)
            return
        }

        // Fecha qualquer pré-aquecimento antes de abrir a captura da saída.
        await microphone.coolDown()
        do {
            try await systemAudio.prepare()
            try Task.checkCancellation()
        } catch {
            await systemAudio.stop()
            throw error
        }
        let currentMixer = AudioTimelineMixer(origin: hostTime(), sourceGain: includesMicrophone ? 0.5 : 1)
        mixer = currentMixer
        combinedMode.set(true)
        levelMonitor.reset()
        liveEmitter.reset(onSamples: onSamples)
        do {
            try await systemAudio.start { currentMixer.append($0) }
            try Task.checkCancellation()
            if includesMicrophone {
                try await microphone.startTimestamped(
                    deviceUID: deviceUID, onFirstSample: onFirstSample,
                    onChunk: { currentMixer.append($0) }
                )
            } else {
                // A saída pode estar em silêncio até o usuário dar play.
                // Stream iniciado já está pronto; não depende de um tap de mic.
                onFirstSample?()
            }
            try Task.checkCancellation()
            let emitter = liveEmitter
            let monitor = levelMonitor
            let clock = hostTime
            pump = Task {
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(50)) }
                    catch { return }
                    let ready = currentMixer.takeReady(upTo: clock() - 0.25)
                    Self.updateLevel(ready, monitor: monitor)
                    emitter.append(ready)
                }
            }
        } catch {
            _ = await stopSegment()
            await microphone.coolDown()
            throw error
        }
    }

    /// Troca apenas a fonte: histórico e transcrição ao vivo continuam na mesma sessão.
    func switchSource(deviceUID: String?, includesSystemAudio: Bool) async throws {
        try await acquireStartSlot()
        defer { releaseStartSlot() }
        guard sessionActive else { throw RecordingSourceSwitchError.noActiveSession }
        let previousSystem = sessionIncludesSystemAudio
        let previousMicrophone = sessionIncludesMicrophone
        let previousUID = sessionDeviceUID
        completedSegments.append(await stopSegment())
        await microphone.coolDown()
        do {
            try await startSegment(deviceUID: deviceUID, onFirstSample: nil,
                                   onSamples: sessionOnSamples, includesSystemAudio: includesSystemAudio,
                                   includesMicrophone: !includesSystemAudio)
        } catch {
            let switchError = error
            // Se a nova fonte falhar, tenta retomar a anterior sem perder os trechos.
            // Cancelamento pertence ao stop/cancel do controller: não reabre hardware.
            if !Task.isCancelled {
                try? await startSegment(deviceUID: previousUID, onFirstSample: nil,
                                        onSamples: sessionOnSamples, includesSystemAudio: previousSystem,
                                        includesMicrophone: previousMicrophone)
            }
            throw switchError
        }
    }

    private func acquireStartSlot() async throws {
        while startInProgress {
            await withCheckedContinuation { waitingStarts.append($0) }
        }
        try Task.checkCancellation()
        startInProgress = true
    }

    private func releaseStartSlot() {
        startInProgress = false
        let waiting = waitingStarts
        waitingStarts = []
        for continuation in waiting { continuation.resume() }
    }

    func stop() async -> [Float] {
        // Stop/cancel deve aguardar a troca mesmo se sua própria Task foi cancelada.
        while startInProgress {
            await withCheckedContinuation { waitingStarts.append($0) }
        }
        startInProgress = true
        defer { releaseStartSlot() }
        let lastSegment = await stopSegment()
        sessionActive = false
        sessionOnSamples = nil
        guard !completedSegments.isEmpty else { return lastSegment }
        var result: [Float] = []
        result.reserveCapacity(completedSegments.reduce(lastSegment.count) { $0 + $1.count })
        for segment in completedSegments { result.append(contentsOf: segment) }
        result.append(contentsOf: lastSegment)
        completedSegments = []
        return result
    }

    private func stopSegment() async -> [Float] {
        guard let currentMixer = mixer else { return await microphone.stop() }
        pump?.cancel()
        await pump?.value
        pump = nil
        if sessionIncludesMicrophone { _ = await microphone.stop() }
        await systemAudio.stop()
        let result = currentMixer.finish()
        liveEmitter.append(result.remainingLiveSamples)
        liveEmitter.flush()
        liveEmitter.deactivate()
        mixer = nil
        combinedMode.set(false)
        levelMonitor.reset()
        return result.samples
    }

    func warmUp(deviceUID: String?) async throws {
        guard !sessionActive, !startInProgress else { return }
        guard !includesSystemAudio() || includesMicrophone() else {
            await microphone.coolDown()
            return
        }
        try await microphone.warmUp(deviceUID: deviceUID)
    }

    func coolDown() async { await microphone.coolDown() }

    func isReceivingAudio() async -> Bool {
        guard mixer != nil else { return await microphone.isReceivingAudio() }
        let receivingSystem = await systemAudio.isRunning()
        guard sessionIncludesMicrophone else { return receivingSystem }
        return await microphone.isReceivingAudio() && receivingSystem
    }

    private nonisolated static func updateLevel(_ samples: [Float], monitor: AudioLevelMonitor) {
        guard !samples.isEmpty else { return }
        var sum: Float = 0
        var peak: Float = 0
        for sample in samples {
            sum += sample * sample
            peak = max(peak, abs(sample))
        }
        monitor.update(AudioLevelNormalizer.normalizedRMS(sqrt(sum / Float(samples.count))), peak: peak)
    }
}
