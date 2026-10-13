import Foundation
import Testing
@testable import zspeak

@MainActor
@Suite("RecordingController")
struct RecordingControllerTests {

    @Test("initialize só marca modelo pronto depois do warmUp")
    func initializeMarcaModeloProntoDepoisDoWarmUp() async throws {
        let audioCapture = ControlledWarmUpAudioCapture()
        let transcriber = FakeRecordingTranscriber()
        let textInserter = FakeRecordingTextInserter()
        let microphoneManager = MicrophoneManager(skipBundlePermissionCheck: true)
        microphoneManager.permissionState = .authorized

        let controller = RecordingController(
            audioCapture: audioCapture,
            transcriber: transcriber,
            textInserter: textInserter,
            microphoneManager: microphoneManager
        )

        let initializeTask = Task { @MainActor in
            await controller.initialize()
        }

        try await waitUntil(timeout: .seconds(15), interval: .milliseconds(10)) {
            await audioCapture.warmUpStarted
        }

        #expect(controller.isModelReady == false)

        await audioCapture.releaseWarmUp()
        await initializeTask.value

        #expect(controller.isModelReady == true)
        #expect(await transcriber.didInitialize == true)
    }

    @Test("Transcrição ao vivo atualiza overlay e stop cola texto final no foco")
    func liveTranscriptionAtualizaOverlayEFinalColaNoFoco() async throws {
        let audioCapture = LiveFakeAudioCapture()
        let transcriber = LiveFakeTranscriber()
        let textInserter = RecordingTextInserterSpy()
        let microphoneManager = MicrophoneManager(skipBundlePermissionCheck: true)
        microphoneManager.permissionState = .authorized

        let controller = RecordingController(
            audioCapture: audioCapture,
            transcriber: transcriber,
            textInserter: textInserter,
            microphoneManager: microphoneManager
        )
        controller.isModelReady = true
        controller.accessibilityGranted = true

        controller.startRecordingIfIdle()

        try await waitUntilOnMain(timeout: .seconds(15), interval: .milliseconds(10)) {
            controller.liveTranscriptionPreview == "texto parcial"
        }

        #expect(textInserter.insertedTexts.isEmpty)
        #expect(textInserter.replacedTexts.isEmpty)

        controller.stopRecordingIfActive()

        try await waitUntilOnMain(timeout: .seconds(15), interval: .milliseconds(10)) {
            controller.state == .idle
        }

        #expect(textInserter.insertedTexts == ["texto final"])
        #expect(textInserter.replacedTexts.isEmpty)
        #expect(controller.lastTranscription == "texto final")
        #expect(controller.liveTranscriptionPreview == "")
    }

    @Test("Stop fecha o preview antes de drenar áudio pendente e preserva o batch final")
    func stopClosesPreviewBeforeDrainingPipe() async throws {
        let session = FinishUnblocksLiveSession()
        let transcriber = ClosingOrderTranscriber(session: session)
        let textInserter = RecordingTextInserterSpy()
        let microphoneManager = MicrophoneManager(skipBundlePermissionCheck: true)
        microphoneManager.permissionState = .authorized
        let controller = RecordingController(
            audioCapture: LiveFakeAudioCapture(), transcriber: transcriber,
            textInserter: textInserter, microphoneManager: microphoneManager
        )
        controller.isModelReady = true
        controller.accessibilityGranted = true
        controller.startRecordingIfIdle()
        do {
            try await waitUntil { await session.isAppending }
            controller.stopRecordingIfActive()
            try await waitUntilOnMain(timeout: .seconds(2)) { controller.state == .idle }
            #expect(await session.finished)
            #expect(textInserter.insertedTexts == ["batch final completo"])
            #expect(await transcriber.receivedSamples >= 16_000)
        } catch {
            await session.cancel()
            throw error
        }
    }

    @Test("recordingStartedAt ancora no 1º sample e não muda durante a gravação")
    func recordingStartedAtAncoradoNoPrimeiroSample() async throws {
        let audioCapture = LiveFakeAudioCapture()
        let transcriber = LiveFakeTranscriber()
        let textInserter = FakeRecordingTextInserter()
        let microphoneManager = MicrophoneManager(skipBundlePermissionCheck: true)
        microphoneManager.permissionState = .authorized

        let controller = RecordingController(
            audioCapture: audioCapture,
            transcriber: transcriber,
            textInserter: textInserter,
            microphoneManager: microphoneManager
        )
        controller.isModelReady = true
        controller.accessibilityGranted = true

        #expect(controller.recordingStartedAt == nil)

        let antesDoStart = Date()
        controller.startRecordingIfIdle()

        try await waitUntilOnMain(timeout: .seconds(15), interval: .milliseconds(10)) {
            controller.state == .recording
        }

        // Âncora setada junto com a transição para .recording (1º sample)
        let ancora = try #require(controller.recordingStartedAt)
        #expect(ancora >= antesDoStart)

        // A âncora vive no controller e não muda enquanto a gravação continua —
        // é isso que impede o timer do overlay de zerar quando a view é recriada.
        try await Task.sleep(for: .milliseconds(50))
        #expect(controller.recordingStartedAt == ancora)

        controller.stopRecordingIfActive()
        try await waitUntilOnMain(timeout: .seconds(15), interval: .milliseconds(10)) {
            controller.state == .idle
        }
    }

    @Test("trimSpeechForASR injetado substitui o trim RMS no stop")
    func trimSpeechForASRInjetadoEUsado() async throws {
        let audioCapture = LiveFakeAudioCapture()
        let transcriber = LiveFakeTranscriber()
        let textInserter = RecordingTextInserterSpy()
        let microphoneManager = MicrophoneManager(skipBundlePermissionCheck: true)
        microphoneManager.permissionState = .authorized

        let controller = RecordingController(
            audioCapture: audioCapture,
            transcriber: transcriber,
            textInserter: textInserter,
            microphoneManager: microphoneManager
        )
        controller.isModelReady = true
        controller.accessibilityGranted = true

        // Hook do AppState (caminho VAD): registra a chamada e devolve o buffer
        // inteiro como "fala" — o pipeline deve seguir até a transcrição final.
        let hookChamado = AtomicBool()
        controller.trimSpeechForASR = { samples in
            hookChamado.set(true)
            return SpeechTrimResult(
                samples: samples,
                originalSampleCount: samples.count,
                startSampleIndex: 0,
                endSampleIndex: samples.count
            )
        }

        controller.startRecordingIfIdle()
        try await waitUntilOnMain(timeout: .seconds(15), interval: .milliseconds(10)) {
            controller.state == .recording
        }

        controller.stopRecordingIfActive()
        try await waitUntilOnMain(timeout: .seconds(15), interval: .milliseconds(10)) {
            controller.state == .idle
        }

        #expect(hookChamado.current, "o trim injetado deveria ter sido usado no stop")
        #expect(controller.lastTranscription == "texto final")
    }

    @Test("Mic zumbi (start OK sem samples) cai para o default via watchdog")
    func micZumbiCaiParaDefaultViaWatchdog() async throws {
        let suiteName = "recording-tests-zumbi"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let audioCapture = ZombieThenGoodAudioCapture()
        let microphoneManager = MicrophoneManager(skipBundlePermissionCheck: true, defaults: defaults)
        microphoneManager.permissionState = .authorized
        microphoneManager.useSystemDefault = false
        microphoneManager.systemDefaultUIDProvider = { "mic-default" }
        microphoneManager.microphones = [
            MicrophoneInfo(id: "mic-zumbi", name: "Zumbi", isConnected: true)
        ]
        microphoneManager.connectedDevicesProvider = {
            [MicrophoneInfo(id: "mic-zumbi", name: "Zumbi", isConnected: true)]
        }

        let controller = RecordingController(
            audioCapture: audioCapture,
            transcriber: LiveFakeTranscriber(),
            textInserter: RecordingTextInserterSpy(),
            microphoneManager: microphoneManager
        )
        controller.isModelReady = true
        controller.accessibilityGranted = true

        controller.startRecordingIfIdle()

        // O watchdog (2s) precisa derrubar o zumbi e engatar no default.
        try await waitUntilOnMain(timeout: .seconds(15), interval: .milliseconds(25)) {
            controller.state == .recording
        }

        let uids = await audioCapture.startedUIDs
        #expect(uids == ["mic-zumbi", nil], "deveria tentar o preferido e cair para o default")
        #expect(microphoneManager.activeMicrophoneID == nil)

        controller.stopRecordingIfActive()
        try await waitUntilOnMain(timeout: .seconds(15), interval: .milliseconds(25)) {
            controller.state == .idle
        }
    }

    @Test("Todos os microfones bloqueados falha com mensagem clara, sem travar")
    func todosBloqueadosFalhaComMensagem() async throws {
        let suiteName = "recording-tests-bloqueados"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let microphoneManager = MicrophoneManager(skipBundlePermissionCheck: true, defaults: defaults)
        microphoneManager.permissionState = .authorized
        microphoneManager.useSystemDefault = true
        microphoneManager.systemDefaultUIDProvider = { "mic-A" }
        microphoneManager.microphones = [
            MicrophoneInfo(id: "mic-A", name: "Mic A", isConnected: true)
        ]
        microphoneManager.connectedDevicesProvider = {
            [MicrophoneInfo(id: "mic-A", name: "Mic A", isConnected: true)]
        }
        microphoneManager.setBlocked("mic-A", blocked: true)

        let controller = RecordingController(
            audioCapture: LiveFakeAudioCapture(),
            transcriber: LiveFakeTranscriber(),
            textInserter: RecordingTextInserterSpy(),
            microphoneManager: microphoneManager
        )
        controller.isModelReady = true
        controller.accessibilityGranted = true

        controller.startRecordingIfIdle()

        try await waitUntilOnMain(timeout: .seconds(15), interval: .milliseconds(25)) {
            controller.errorMessage != nil && controller.state == .idle
        }
        #expect(controller.errorMessage?.contains("bloqueado") == true)
    }

    @Test("AirPods interrompidos encerram gravação, preservam texto e permitem usar de novo")
    func interruptedCaptureRecoversWithoutAppRestart() async throws {
        let suiteName = "recording-interruption-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let microphoneManager = MicrophoneManager(skipBundlePermissionCheck: true, defaults: defaults)
        let audioCapture = InterruptibleAudioCapture()
        let controller = RecordingController(
            audioCapture: audioCapture,
            transcriber: LiveFakeTranscriber(),
            textInserter: RecordingTextInserterSpy(),
            microphoneManager: microphoneManager
        )
        controller.isModelReady = true

        controller.accessibilityGranted = true

        controller.startRecordingIfIdle()
        try await waitUntilOnMain { controller.state == .recording }
        await audioCapture.interrupt()
        try await waitUntilOnMain { controller.state == .idle }
        #expect(controller.lastTranscription == "texto final")
        #expect(controller.errorMessage?.contains("microfone") == true)

        controller.startRecordingIfIdle()
        try await waitUntilOnMain { controller.state == .recording }
        #expect(controller.errorMessage == nil)
        controller.cancelRecording()
        try await waitUntil { await audioCapture.stopCount == 2 }
    }

    @Test("Atualiza dispositivos antes de gravar para reconhecer AirPods recém-conectados")
    func refreshesDevicesBeforeRecording() async throws {
        let suiteName = "recording-reconnect-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(["airpods-pro-3", "macbook"], forKey: "microphonePriorityOrder")
        let microphoneManager = MicrophoneManager(skipBundlePermissionCheck: true, defaults: defaults)
        microphoneManager.useSystemDefault = false
        microphoneManager.systemDefaultUIDProvider = { "macbook" }
        microphoneManager.microphones = [
            MicrophoneInfo(id: "airpods-pro-3", name: "AirPods Pro 3", isConnected: false),
            MicrophoneInfo(id: "macbook", name: "MacBook", isConnected: true),
        ]
        microphoneManager.connectedDevicesProvider = {
            [MicrophoneInfo(id: "airpods-pro-3", name: "AirPods Pro 3", isConnected: true),
             MicrophoneInfo(id: "macbook", name: "MacBook", isConnected: true)]
        }
        let audioCapture = InterruptibleAudioCapture()
        let controller = RecordingController(
            audioCapture: audioCapture,
            transcriber: LiveFakeTranscriber(),
            textInserter: RecordingTextInserterSpy(),
            microphoneManager: microphoneManager
        )
        controller.isModelReady = true
        controller.startRecordingIfIdle()
        try await waitUntilOnMain { controller.state == .recording }
        #expect(await audioCapture.startedUIDs == ["airpods-pro-3"])
        controller.cancelRecording()
        try await waitUntil { await audioCapture.stopCount == 1 }
    }

    @Test("Só computador ignora microfone negado/bloqueado, não aquece e não tenta fallback")
    func systemOnlyBypassesMicrophoneRequirements() async throws {
        let suite = "system-only-controller-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = MicrophoneManager(skipBundlePermissionCheck: true, defaults: defaults)
        manager.permissionState = .denied
        manager.connectedDevicesProvider = { [] }
        manager.systemDefaultUIDProvider = { nil }
        let capture = SystemOnlyControllerCapture()
        let controller = RecordingController(
            audioCapture: capture, transcriber: LiveFakeTranscriber(),
            textInserter: RecordingTextInserterSpy(), microphoneManager: manager,
            includesSystemAudio: { true }, includesMicrophone: { false }
        )
        controller.isModelReady = true
        await controller.warmUpAudioCapture()
        #expect(await capture.warmUps == 0)
        controller.startRecordingIfIdle()
        try await waitUntilOnMain { controller.state == .recording }
        #expect(await capture.starts == 1)
        #expect(await capture.requestedMicrophone == false)
        #expect(controller.recordingIncludesMicrophone == false)
        #expect(manager.activeMicrophoneID == nil)
        #expect(controller.errorMessage == nil)
        controller.cancelRecording()
        try await waitUntil { await capture.stops == 1 }
        await controller.warmUpAudioCapture()
        #expect(await capture.warmUps == 0)
    }

    @Test("Atalho troca fonte mantendo timer, preview e estado; stop espera a troca")
    func sourceSwitchKeepsRecordingAndStopWaits() async throws {
        let suite = "source-switch-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = MicrophoneManager(skipBundlePermissionCheck: true, defaults: defaults)
        let capture = ControlledSourceSwitchCapture()
        var system = true
        let controller = RecordingController(
            audioCapture: capture, transcriber: LiveFakeTranscriber(),
            textInserter: RecordingTextInserterSpy(), microphoneManager: manager,
            includesSystemAudio: { system }, includesMicrophone: { false },
            setRecordingSource: { system = $0 }
        )
        controller.isModelReady = true
        controller.startRecordingIfIdle()
        try await waitUntilOnMain { controller.state == .recording }
        let anchor = controller.recordingStartedAt
        controller.liveTranscriptionPreview = "texto já capturado"
        controller.toggleRecordingSource()
        try await waitUntil { await capture.switchStarted }
        #expect(controller.state == .recording)
        #expect(controller.recordingStartedAt == anchor)
        #expect(controller.liveTranscriptionPreview == "texto já capturado")
        #expect(controller.recordingSourceLabel == "Trocando fonte…")
        controller.toggleRecordingSource() // Tecla repetida não inicia troca concorrente.
        #expect(await capture.switches == 1)
        await capture.releaseSwitch()
        try await waitUntilOnMain { !controller.isSwitchingAudioSource }
        #expect(controller.recordingSourceLabel == "Microfone")
        #expect(system == false)
        #expect(controller.recordingStartedAt == anchor)
        controller.toggleRecordingSource()
        try await waitUntil { await capture.switches == 2 }
        controller.stopRecordingIfActive()
        #expect(controller.state == .processing)
        #expect(await capture.stops == 0)
        await capture.releaseSwitch()
        try await waitUntilOnMain { controller.state == .idle }
        #expect(await capture.stops == 1)
        #expect(controller.lastTranscription == "texto final")
        #expect(system)
    }

    @Test("Troca aguarda Bluetooth abrir, mas encerra se a nova fonte continuar sem áudio", arguments: [true, false])
    func sourceSwitchAllowsMicrophoneStartup(receivesAudio: Bool) async throws {
        let manager = MicrophoneManager(skipBundlePermissionCheck: true)
        let capture = ControlledSourceSwitchCapture()
        let controller = RecordingController(
            audioCapture: capture, transcriber: LiveFakeTranscriber(),
            textInserter: RecordingTextInserterSpy(), microphoneManager: manager,
            includesSystemAudio: { true }, includesMicrophone: { false }
        )
        controller.isModelReady = true
        controller.accessibilityGranted = true
        controller.startRecordingIfIdle()
        defer { controller.cancelRecording() }
        try await waitUntilOnMain { controller.state == .recording }
        controller.toggleRecordingSource()
        try await waitUntil { await capture.switchStarted }
        await capture.setReceiving(false)
        await capture.releaseSwitch()
        try await waitUntilOnMain { !controller.isSwitchingAudioSource }
        try await waitUntil { await capture.healthChecks >= 2 }
        #expect(controller.state == .recording, "Bluetooth ainda pode estar abrindo após 500 ms")
        if receivesAudio {
            await capture.setReceiving(true)
            try await waitUntil(timeout: .seconds(3)) { await capture.healthChecks >= 9 }
            #expect(controller.state == .recording)
        } else {
            try await waitUntilOnMain(timeout: .seconds(3)) { controller.state == .idle }
            #expect(controller.lastTranscription == "texto final")
            #expect(controller.errorMessage?.contains("microfone") == true)
        }
    }

    @Test("Atalho ocioso alterna somente a preferência sem começar gravação")
    func idleShortcutOnlySelectsSource() async throws {
        let manager = MicrophoneManager(skipBundlePermissionCheck: true)
        let capture = ControlledSourceSwitchCapture()
        var system = true
        let controller = RecordingController(
            audioCapture: capture, transcriber: LiveFakeTranscriber(),
            textInserter: RecordingTextInserterSpy(), microphoneManager: manager,
            includesSystemAudio: { system }, includesMicrophone: { false },
            setRecordingSource: { system = $0 }
        )
        controller.toggleRecordingSource()
        #expect(system == false)
        #expect(controller.recordingSourceLabel == "Microfone")
        controller.toggleRecordingSource()
        #expect(system)
        #expect(controller.state == .idle)
        #expect(await capture.switches == 0)
    }

    @Test("Permissão de áudio do computador mostra orientação sem tentar outros microfones")
    func systemAudioPermissionErrorIsActionable() async throws {
        let suiteName = "recording-system-permission-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let microphoneManager = MicrophoneManager(skipBundlePermissionCheck: true, defaults: defaults)
        microphoneManager.useSystemDefault = false
        microphoneManager.connectedDevicesProvider = {
            [MicrophoneInfo(id: "mic-one", name: "Microfone", isConnected: true)]
        }
        let capture = SystemPermissionDeniedCapture()
        let controller = RecordingController(
            audioCapture: capture, transcriber: LiveFakeTranscriber(),
            textInserter: RecordingTextInserterSpy(), microphoneManager: microphoneManager,
            includesSystemAudio: { true }
        )
        controller.isModelReady = true
        controller.startRecordingIfIdle()
        try await waitUntilOnMain { controller.state == .idle && controller.errorMessage != nil }
        #expect(controller.errorMessage?.contains("Gravação de tela e áudio do sistema") == true)
        #expect(await capture.startCount == 1)
    }
}

private actor FinishUnblocksLiveSession: LiveTranscriptionSession {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var isAppending = false
    private(set) var finished = false
    func append(_ samples: [Float]) async {
        guard !finished else { return }
        isAppending = true
        await withCheckedContinuation { continuation = $0 }
    }
    func finish() async throws -> String {
        finished = true
        continuation?.resume(); continuation = nil
        return "preview"
    }
    func cancel() async { _ = try? await finish() }
}

private actor ClosingOrderTranscriber: Transcribing {
    let session: FinishUnblocksLiveSession
    private(set) var receivedSamples = 0
    init(session: FinishUnblocksLiveSession) { self.session = session }
    func initialize() async throws {}
    func startLiveTranscription(onUpdate: @escaping @Sendable (LiveTranscriptionUpdate) -> Void) async throws -> any LiveTranscriptionSession { session }
    func transcribe(_ samples: [Float]) async throws -> String {
        receivedSamples = samples.count
        return "batch final completo"
    }
}

private actor SystemPermissionDeniedCapture: AudioCapturing {
    private(set) var startCount = 0
    nonisolated func currentAudioLevel() -> Float { 0 }
    nonisolated func isInputClipping() -> Bool { false }
    func start(deviceUID: String?, onFirstSample: (@Sendable () -> Void)?, onSamples: (@Sendable ([Float]) -> Void)?) async throws {
        startCount += 1
        throw SystemAudioCaptureError.permissionRequired
    }
    func stop() async -> [Float] { [] }
    func warmUp(deviceUID: String?) async throws {}
    func coolDown() {}
}

private actor InterruptibleAudioCapture: AudioCapturing {
    private var healthy = false
    private(set) var stopCount = 0
    private(set) var startedUIDs: [String?] = []
    nonisolated func currentAudioLevel() -> Float { 0 }
    nonisolated func isInputClipping() -> Bool { false }
    func start(deviceUID: String?, onFirstSample: (@Sendable () -> Void)?, onSamples: (@Sendable ([Float]) -> Void)?) async throws {
        startedUIDs.append(deviceUID)
        healthy = true
        onFirstSample?()
    }
    func stop() async -> [Float] {
        stopCount += 1
        healthy = false
        return Array(repeating: 0.05, count: 16_000)
    }
    func warmUp(deviceUID: String?) async throws {}
    func coolDown() {}
    func isReceivingAudio() -> Bool { healthy }
    func interrupt() { healthy = false }
}

/// Mock do bug real: device específico "inicia" o engine mas nunca entrega
/// samples (zumbi); o default do sistema funciona. O watchdog do controller
/// deve detectar e cair para o default.
private actor ZombieThenGoodAudioCapture: AudioCapturing {
    private(set) var startedUIDs: [String?] = []

    nonisolated func currentAudioLevel() -> Float { 0 }
    nonisolated func isInputClipping() -> Bool { false }

    func start(
        deviceUID: String?,
        onFirstSample: (@Sendable () -> Void)?,
        onSamples: (@Sendable ([Float]) -> Void)?
    ) async throws {
        startedUIDs.append(deviceUID)
        guard deviceUID == nil else { return } // zumbi: sem onFirstSample
        onFirstSample?()
        onSamples?([Float](repeating: 0.05, count: 4_000))
    }

    func stop() async -> [Float] {
        [Float](repeating: 0.05, count: 16_000)
    }

    func warmUp(deviceUID: String?) async throws {}
    func coolDown() {}
}

private actor ControlledWarmUpAudioCapture: AudioCapturing {
    private(set) var warmUpStarted = false
    private var warmUpContinuation: CheckedContinuation<Void, Never>?

    nonisolated func currentAudioLevel() -> Float { 0 }
    nonisolated func isInputClipping() -> Bool { false }

    func start(
        deviceUID: String?,
        onFirstSample: (@Sendable () -> Void)?,
        onSamples: (@Sendable ([Float]) -> Void)?
    ) async throws {
        onFirstSample?()
    }

    func stop() async -> [Float] { [] }

    func warmUp(deviceUID: String?) async throws {
        warmUpStarted = true
        await withCheckedContinuation { continuation in
            warmUpContinuation = continuation
        }
    }

    func coolDown() {}

    func releaseWarmUp() {
        warmUpContinuation?.resume()
        warmUpContinuation = nil
    }
}

private actor FakeRecordingTranscriber: Transcribing {
    private(set) var didInitialize = false

    func initialize() async throws {
        didInitialize = true
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        "texto"
    }

    func startLiveTranscription(
        onUpdate: @escaping @Sendable (LiveTranscriptionUpdate) -> Void
    ) async throws -> any LiveTranscriptionSession {
        FakeLiveTranscriptionSession()
    }
}

private actor FakeLiveTranscriptionSession: LiveTranscriptionSession {
    func append(_ samples: [Float]) async {}
    func finish() async throws -> String { "" }
    func cancel() async {}
}

private actor LiveFakeAudioCapture: AudioCapturing {
    nonisolated func currentAudioLevel() -> Float { 0.5 }
    nonisolated func isInputClipping() -> Bool { false }

    func start(
        deviceUID: String?,
        onFirstSample: (@Sendable () -> Void)?,
        onSamples: (@Sendable ([Float]) -> Void)?
    ) async throws {
        onFirstSample?()
        onSamples?([Float](repeating: 0.05, count: 4_000))
    }

    func stop() async -> [Float] {
        [Float](repeating: 0.05, count: 16_000)
    }

    func warmUp(deviceUID: String?) async throws {}
    func coolDown() {}
}

private actor LiveFakeTranscriber: Transcribing {
    func initialize() async throws {}

    func transcribe(_ samples: [Float]) async throws -> String {
        "texto final"
    }

    func startLiveTranscription(
        onUpdate: @escaping @Sendable (LiveTranscriptionUpdate) -> Void
    ) async throws -> any LiveTranscriptionSession {
        LiveFakeTranscriptionSession(onUpdate: onUpdate)
    }
}

private actor LiveFakeTranscriptionSession: LiveTranscriptionSession {
    private let onUpdate: @Sendable (LiveTranscriptionUpdate) -> Void
    private var didEmit = false

    init(onUpdate: @escaping @Sendable (LiveTranscriptionUpdate) -> Void) {
        self.onUpdate = onUpdate
    }

    func append(_ samples: [Float]) async {
        guard !didEmit else { return }
        didEmit = true
        onUpdate(LiveTranscriptionUpdate(
            text: "texto parcial",
            isConfirmed: false,
            confidence: 0.7
        ))
    }

    func finish() async throws -> String {
        "texto parcial"
    }

    func cancel() async {}
}

@MainActor
private final class RecordingTextInserterSpy: TextInserting {
    private(set) var insertedTexts: [String] = []
    private(set) var replacedTexts: [String] = []
    private(set) var copiedTexts: [String] = []

    func insert(_ text: String) async -> Bool {
        insertedTexts.append(text)
        TextInserter.lastPastedCount = text.count
        return true
    }

    func copyToClipboard(_ text: String) {
        copiedTexts.append(text)
    }

    func replaceLastPaste(_ newText: String) async -> Bool {
        replacedTexts.append(newText)
        TextInserter.lastPastedCount = newText.count
        return true
    }
}

@MainActor
private final class FakeRecordingTextInserter: TextInserting {
    func insert(_ text: String) async -> Bool { true }
    func copyToClipboard(_ text: String) {}
    func replaceLastPaste(_ newText: String) async -> Bool { true }
}

private actor SystemOnlyControllerCapture: AudioCapturing {
    private(set) var starts = 0
    private(set) var stops = 0
    private(set) var warmUps = 0
    private(set) var requestedMicrophone = true
    nonisolated func currentAudioLevel() -> Float { 0 }
    nonisolated func isInputClipping() -> Bool { false }
    func start(deviceUID: String?, onFirstSample: (@Sendable () -> Void)?, onSamples: (@Sendable ([Float]) -> Void)?) async throws {
        Issue.record("Modo somente computador deve passar as fontes congeladas")
    }
    func start(deviceUID: String?, onFirstSample: (@Sendable () -> Void)?, onSamples: (@Sendable ([Float]) -> Void)?, includesSystemAudio: Bool, includesMicrophone: Bool) async throws {
        starts += 1
        requestedMicrophone = includesMicrophone
        #expect(includesSystemAudio)
        #expect(deviceUID == nil)
        onFirstSample?()
    }
    func stop() -> [Float] { stops += 1; return [] }
    func warmUp(deviceUID: String?) { warmUps += 1 }
    func coolDown() {}
}

private actor ControlledSourceSwitchCapture: AudioCapturing {
    private(set) var switchStarted = false
    private(set) var switches = 0
    private(set) var stops = 0
    private(set) var healthChecks = 0
    private var receiving = true
    private var pendingSwitch: CheckedContinuation<Void, Never>?
    nonisolated func currentAudioLevel() -> Float { 0 }
    nonisolated func isInputClipping() -> Bool { false }
    func start(deviceUID: String?, onFirstSample: (@Sendable () -> Void)?, onSamples: (@Sendable ([Float]) -> Void)?) async throws { onFirstSample?() }
    func switchSource(deviceUID: String?, includesSystemAudio: Bool) async throws {
        switches += 1
        switchStarted = true
        await withCheckedContinuation { pendingSwitch = $0 }
    }
    func releaseSwitch() { pendingSwitch?.resume(); pendingSwitch = nil }
    func stop() -> [Float] { stops += 1; return [Float](repeating: 0.1, count: 16_000) }
    func warmUp(deviceUID: String?) {}
    func coolDown() {}
    func setReceiving(_ value: Bool) { receiving = value; healthChecks = 0 }
    func isReceivingAudio() -> Bool { healthChecks += 1; return receiving }
}
