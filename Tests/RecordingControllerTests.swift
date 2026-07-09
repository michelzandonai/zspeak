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
