import Foundation
import Testing
@testable import zspeak

@Suite("RecordingAudioCapture")
struct RecordingAudioCaptureTests {
    @Test("Modo microfone não prepara nem captura áudio do computador")
    func microphoneOnlyDoesNotCaptureSystem() async throws {
        let microphone = TimestampedMicrophoneSpy()
        let system = SystemAudioCaptureSpy()
        let capture = RecordingAudioCapture(microphone: microphone, systemAudio: system, includesSystemAudio: { false })
        try await capture.start(deviceUID: "airpods", onFirstSample: nil, onSamples: nil)
        #expect(await microphone.normalStarts == 1)
        #expect(await microphone.timedStarts == 0)
        #expect(await system.prepareCount == 0)
        let samples = await capture.stop()
        #expect(samples == [0.25])
        #expect(await system.stopCount == 0)
    }

    @Test("Fonte da sessão prevalece sobre preferência alterada depois do atalho")
    func frozenSessionSourceOverridesCurrentPreference() async throws {
        let microphone = TimestampedMicrophoneSpy()
        let system = SystemAudioCaptureSpy()
        let capture = RecordingAudioCapture(microphone: microphone, systemAudio: system, includesSystemAudio: { true }, includesMicrophone: { true }, hostTime: { 10 })
        // O usuário ligou a preferência depois de começar uma sessão só de mic.
        try await capture.start(deviceUID: nil, onFirstSample: nil, onSamples: nil, includesSystemAudio: false)
        #expect(await system.startCount == 0)
        #expect(await microphone.normalStarts == 1)
        _ = await capture.stop()

        try await capture.start(deviceUID: nil, onFirstSample: nil, onSamples: nil, includesSystemAudio: true)
        #expect(await system.startCount == 1)
        #expect(await microphone.timedStarts == 1)
        _ = await capture.stop()
    }

    @Test("Recomeçar só com microfone fecha a sessão combinada anterior")
    func restartingDoesNotLeaveOldSystemCaptureOpen() async throws {
        let microphone = TimestampedMicrophoneSpy()
        let system = SystemAudioCaptureSpy()
        let capture = RecordingAudioCapture(microphone: microphone, systemAudio: system, includesSystemAudio: { true }, includesMicrophone: { true }, hostTime: { 10 })
        try await capture.start(deviceUID: nil, onFirstSample: nil, onSamples: nil, includesSystemAudio: true)
        try await capture.start(deviceUID: nil, onFirstSample: nil, onSamples: nil, includesSystemAudio: false)
        #expect(await system.stopCount == 1)
        #expect(await system.isRunning() == false)
        #expect(await microphone.normalStarts == 1)
        _ = await capture.stop()
    }

    @Test("Recomeço após cancelar preparo aguarda limpeza da sessão cancelada")
    func newSessionWaitsForCancelledPreparation() async throws {
        let microphone = TimestampedMicrophoneSpy()
        let system = PendingSystemAudioCaptureSpy()
        let capture = RecordingAudioCapture(microphone: microphone, systemAudio: system, includesSystemAudio: { true }, includesMicrophone: { true })
        let first = Task { try await capture.start(deviceUID: nil, onFirstSample: nil, onSamples: nil, includesSystemAudio: true) }
        try await waitUntil { await system.preparing }
        first.cancel()
        let second = Task { try await capture.start(deviceUID: nil, onFirstSample: nil, onSamples: nil, includesSystemAudio: false) }
        await system.release()
        do { try await first.value; Issue.record("Primeira sessão deveria ser cancelada") }
        catch { #expect(error is CancellationError) }
        try await second.value
        #expect(await microphone.normalStarts == 1)
        #expect(await system.stopCount == 1)
        _ = await capture.stop()
    }

    @Test("Modo combinado entrega mistura e cauda das duas fontes ao histórico e preview")
    func combinedCapturePreservesBothSourcesAndTail() async throws {
        let microphone = TimestampedMicrophoneSpy()
        let system = SystemAudioCaptureSpy()
        let live = CapturedSampleSpy()
        let capture = RecordingAudioCapture(
            microphone: microphone, systemAudio: system,
            includesSystemAudio: { true }, includesMicrophone: { true }, hostTime: { 10 }
        )
        try await capture.start(deviceUID: "airpods", onFirstSample: nil, onSamples: { live.append($0) })
        #expect(await microphone.normalStarts == 0)
        #expect(await microphone.timedStarts == 1)
        #expect(await capture.isReceivingAudio())
        let samples = await capture.stop()
        #expect(samples.count == 6)
        #expect(abs(samples[0] - 0.4) < 0.00001)
        #expect(abs(samples[2] - 0.7) < 0.00001)
        #expect(samples.suffix(2).allSatisfy { abs($0 - 0.3) < 0.00001 })
        #expect(live.samples == samples)
        #expect(await system.isRunning() == false)
        #expect(await system.stopCount == 1)
    }

    @Test("Vídeo em silêncio não interrompe o microfone; perda de uma fonte é detectada")
    func healthChecksBothStreamsWithoutRequiringPlayback() async throws {
        let microphone = TimestampedMicrophoneSpy()
        let system = SystemAudioCaptureSpy()
        let capture = RecordingAudioCapture(microphone: microphone, systemAudio: system, includesSystemAudio: { true }, includesMicrophone: { true }, hostTime: { 10 })
        try await capture.start(deviceUID: nil, onFirstSample: nil, onSamples: nil)
        #expect(await capture.isReceivingAudio())
        await system.setRunning(false)
        #expect(await capture.isReceivingAudio() == false)
        await system.setRunning(true)
        await microphone.setReceiving(false)
        #expect(await capture.isReceivingAudio() == false)
        _ = await capture.stop()
    }

    @Test("Permissão negada não inicia microfone nem continua apenas com uma fonte")
    func permissionDeniedDoesNotSilentlyRecordMicrophone() async {
        let microphone = TimestampedMicrophoneSpy()
        let system = SystemAudioCaptureSpy(denyPermission: true)
        let capture = RecordingAudioCapture(microphone: microphone, systemAudio: system, includesSystemAudio: { true }, includesMicrophone: { true })
        do {
            try await capture.start(deviceUID: nil, onFirstSample: nil, onSamples: nil)
            Issue.record("Deveria exigir permissão para áudio do computador")
        } catch {
            #expect(error is SystemAudioCaptureError)
        }
        #expect(await microphone.timedStarts == 0)
        #expect(await microphone.normalStarts == 0)
        #expect(await system.startCount == 0)
        #expect(await system.isRunning() == false)
    }

    @Test("Falha do microfone encerra a captura do computador e permite tentar de novo")
    func microphoneFailureCleansUpSystemStream() async throws {
        let microphone = TimestampedMicrophoneSpy(failStart: true)
        let system = SystemAudioCaptureSpy()
        let capture = RecordingAudioCapture(microphone: microphone, systemAudio: system, includesSystemAudio: { true }, includesMicrophone: { true }, hostTime: { 10 })
        do {
            try await capture.start(deviceUID: nil, onFirstSample: nil, onSamples: nil)
            Issue.record("Deveria falhar ao iniciar microfone")
        } catch {}
        #expect(await system.isRunning() == false)
        #expect(await system.stopCount == 1)
        await microphone.setFailStart(false)
        try await capture.start(deviceUID: nil, onFirstSample: nil, onSamples: nil)
        #expect(await capture.isReceivingAudio())
        _ = await capture.stop()
        #expect(await system.stopCount == 2)
    }

    @Test("Pré-aquecimento aquece apenas microfone, sem escutar outros apps em idle")
    func warmUpNeverStartsSystemStream() async throws {
        let microphone = TimestampedMicrophoneSpy()
        let system = SystemAudioCaptureSpy()
        let capture = RecordingAudioCapture(microphone: microphone, systemAudio: system, includesSystemAudio: { true }, includesMicrophone: { true })
        try await capture.warmUp(deviceUID: nil)
        #expect(await microphone.warmUpCount == 1)
        #expect(await system.prepareCount == 0)
        #expect(await system.startCount == 0)
    }

    @Test("Cancelar durante a permissão/preparo não deixa stream ativo")
    func cancellationDuringPreparationCleansUp() async throws {
        let microphone = TimestampedMicrophoneSpy()
        let system = PendingSystemAudioCaptureSpy()
        let capture = RecordingAudioCapture(microphone: microphone, systemAudio: system, includesSystemAudio: { true }, includesMicrophone: { true })
        let start = Task { try await capture.start(deviceUID: nil, onFirstSample: nil, onSamples: nil) }
        try await waitUntil { await system.preparing }
        start.cancel()
        await system.release()
        do {
            try await start.value
            Issue.record("Deveria cancelar a preparação")
        } catch { #expect(error is CancellationError) }
        #expect(await microphone.timedStarts == 0)
        #expect(await system.stopCount == 1)
    }

    @Test("Só computador não abre nem aquece o microfone, preserva ganho e cauda")
    func systemOnlyNeverOpensMicrophone() async throws {
        let microphone = TimestampedMicrophoneSpy(failStart: true)
        let system = SystemAudioCaptureSpy()
        let live = CapturedSampleSpy()
        let ready = AtomicInt()
        let capture = RecordingAudioCapture(
            microphone: microphone, systemAudio: system,
            includesSystemAudio: { true }, includesMicrophone: { false }, hostTime: { 10 }
        )
        try await capture.warmUp(deviceUID: "airpods")
        try await capture.start(deviceUID: "airpods", onFirstSample: { ready.increment() }, onSamples: { live.append($0) })
        #expect(ready.current == 1)
        #expect(await microphone.normalStarts == 0)
        #expect(await microphone.timedStarts == 0)
        #expect(await microphone.warmUpCount == 0)
        #expect(await capture.isReceivingAudio())
        let samples = await capture.stop()
        #expect(samples == [0, 0, 0.6, 0.6, 0.6, 0.6])
        #expect(live.samples == samples)
        #expect(await system.isRunning() == false)
        try await capture.warmUp(deviceUID: "airpods")
        #expect(await microphone.warmUpCount == 0)
    }

    @Test("Só computador fica pronto em silêncio e detecta interrupção da saída")
    func systemOnlyIsReadyBeforePlayback() async throws {
        let microphone = TimestampedMicrophoneSpy(failStart: true)
        let system = SystemAudioCaptureSpy(silent: true)
        let ready = AtomicInt()
        let capture = RecordingAudioCapture(
            microphone: microphone, systemAudio: system,
            includesSystemAudio: { true }, includesMicrophone: { false }, hostTime: { 10 }
        )
        try await capture.start(deviceUID: nil, onFirstSample: { ready.increment() }, onSamples: nil)
        #expect(ready.current == 1)
        #expect(await capture.isReceivingAudio())
        await system.setRunning(false)
        #expect(await capture.isReceivingAudio() == false)
        #expect(await capture.stop().isEmpty)
    }

    @Test("Escolha do microfone fica congelada na sessão mesmo se a preferência mudar")
    func frozenMicrophoneSourceOverridesPreference() async throws {
        let microphone = TimestampedMicrophoneSpy(failStart: true)
        let system = SystemAudioCaptureSpy()
        let capture = RecordingAudioCapture(
            microphone: microphone, systemAudio: system,
            includesSystemAudio: { true }, includesMicrophone: { true }, hostTime: { 10 }
        )
        try await capture.start(deviceUID: "airpods", onFirstSample: nil, onSamples: nil,
                                includesSystemAudio: true, includesMicrophone: false)
        #expect(await microphone.timedStarts == 0)
        #expect(await capture.isReceivingAudio())
        _ = await capture.stop()
    }

    @Test("Alternar computador, voz e computador preserva uma sessão e o preview sem duplicar áudio")
    func switchSourcesKeepsEverySegment() async throws {
        let microphone = TimestampedMicrophoneSpy()
        let system = SystemAudioCaptureSpy()
        let live = CapturedSampleSpy()
        let first = AtomicInt()
        let capture = RecordingAudioCapture(
            microphone: microphone, systemAudio: system,
            includesSystemAudio: { true }, includesMicrophone: { false }, hostTime: { 10 }
        )
        try await capture.start(deviceUID: nil, onFirstSample: { first.increment() }, onSamples: { live.append($0) })
        try await capture.switchSource(deviceUID: "mic", includesSystemAudio: false)
        #expect(await system.isRunning() == false)
        #expect(await microphone.normalStarts == 1)
        #expect(await capture.isReceivingAudio())
        try await capture.switchSource(deviceUID: nil, includesSystemAudio: true)
        #expect(await microphone.isReceivingAudio() == false)
        #expect(await system.isRunning())
        let samples = await capture.stop()
        let computer: [Float] = [0, 0, 0.6, 0.6, 0.6, 0.6]
        #expect(samples == computer + [0.25] + computer)
        #expect(live.samples == samples)
        #expect(first.current == 1)
        #expect(await microphone.timedStarts == 0)
    }

    @Test("Falha ao trocar para microfone retoma computador sem perder áudio anterior")
    func switchFailureRestoresPreviousSource() async throws {
        let microphone = TimestampedMicrophoneSpy(failStart: true)
        let system = SystemAudioCaptureSpy()
        let capture = RecordingAudioCapture(
            microphone: microphone, systemAudio: system,
            includesSystemAudio: { true }, includesMicrophone: { false }, hostTime: { 10 }
        )
        try await capture.start(deviceUID: nil, onFirstSample: nil, onSamples: nil)
        do {
            try await capture.switchSource(deviceUID: "mic", includesSystemAudio: false)
            Issue.record("Deveria falhar ao trocar para o microfone")
        } catch { #expect(error is AudioCaptureError) }
        #expect(await capture.isReceivingAudio())
        #expect(await system.startCount == 2)
        let computer: [Float] = [0, 0, 0.6, 0.6, 0.6, 0.6]
        #expect(await capture.stop() == computer + computer)
    }

    @Test("Permissão negada na troca retoma microfone e preserva os trechos")
    func deniedSwitchRestoresMicrophone() async throws {
        let microphone = TimestampedMicrophoneSpy()
        let system = SystemAudioCaptureSpy(denyPermission: true)
        let capture = RecordingAudioCapture(microphone: microphone, systemAudio: system, includesSystemAudio: { false })
        try await capture.start(deviceUID: nil, onFirstSample: nil, onSamples: nil)
        do {
            try await capture.switchSource(deviceUID: nil, includesSystemAudio: true)
            Issue.record("Deveria exigir permissão da captura do computador")
        } catch { #expect(error is SystemAudioCaptureError) }
        #expect(await capture.isReceivingAudio())
        #expect(await microphone.normalStarts == 2)
        #expect(await capture.stop() == [0.25, 0.25])
    }

    @Test("Parar durante troca aguarda limpeza e preserva trecho anterior")
    func stoppingDuringSourceSwitchPreservesCapturedAudio() async throws {
        let microphone = TimestampedMicrophoneSpy()
        let system = PendingSystemAudioCaptureSpy()
        let capture = RecordingAudioCapture(microphone: microphone, systemAudio: system, includesSystemAudio: { false })
        try await capture.start(deviceUID: nil, onFirstSample: nil, onSamples: nil)
        let switching = Task { try await capture.switchSource(deviceUID: nil, includesSystemAudio: true) }
        try await waitUntil { await system.preparing }
        let stopping = Task { await capture.stop() }
        switching.cancel()
        await system.release()
        do { try await switching.value; Issue.record("Troca deveria cancelar") }
        catch { #expect(error is CancellationError) }
        // O mock de mic retorna o mesmo buffer em cada stop; uma fonte parada
        // não deve ser drenada novamente ao cancelar a preparação da próxima.
        let result = await stopping.value
        #expect(result == [0.25])
        #expect(await system.isRunning() == false)
    }

    @MainActor
    @Test("Overlay mostra as duas fontes quando o modo combinado está ativo")
    func overlayIdentifiesCombinedSource() {
        let model = OverlayModel()
        model.microphoneName = "AirPods Pro 3"
        #expect(model.effectiveMicrophoneName == "AirPods Pro 3")
        model.includesSystemAudio = true
        #expect(model.effectiveMicrophoneName == "AirPods Pro 3 + áudio do computador")
        model.includesMicrophone = false
        #expect(model.effectiveMicrophoneName == "Áudio do computador")
    }
}

private actor PendingSystemAudioCaptureSpy: SystemAudioCapturing {
    private(set) var preparing = false
    private(set) var stopCount = 0
    private var continuation: CheckedContinuation<Void, Never>?
    func prepare() async throws {
        preparing = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
    func start(onChunk: @escaping @Sendable (TimestampedAudioChunk) -> Void) async throws {}
    func stop() { stopCount += 1 }
    func isRunning() -> Bool { false }
}

private actor TimestampedMicrophoneSpy: TimestampedMicrophoneCapturing {
    private(set) var normalStarts = 0
    private(set) var timedStarts = 0
    private(set) var warmUpCount = 0
    private var receiving = false
    private var failStart: Bool
    init(failStart: Bool = false) { self.failStart = failStart }
    nonisolated func currentAudioLevel() -> Float { 0 }
    nonisolated func isInputClipping() -> Bool { false }
    func start(deviceUID: String?, onFirstSample: (@Sendable () -> Void)?, onSamples: (@Sendable ([Float]) -> Void)?) async throws {
        normalStarts += 1
        if failStart { throw AudioCaptureError.invalidFormat }
        receiving = true
        onSamples?([0.25])
        onFirstSample?()
    }
    func startTimestamped(deviceUID: String?, onFirstSample: (@Sendable () -> Void)?, onChunk: @escaping @Sendable (TimestampedAudioChunk) -> Void) async throws {
        timedStarts += 1
        if failStart { throw AudioCaptureError.invalidFormat }
        receiving = true
        onChunk(TimestampedAudioChunk(startTime: 10, samples: [0.8, 0.8, 0.8, 0.8]))
        onFirstSample?()
    }
    func stop() async -> [Float] { let wasReceiving = receiving; receiving = false; return wasReceiving ? [0.25] : [] }
    func warmUp(deviceUID: String?) async throws { warmUpCount += 1 }
    func coolDown() {}
    func isReceivingAudio() -> Bool { receiving }
    func setReceiving(_ value: Bool) { receiving = value }
    func setFailStart(_ value: Bool) { failStart = value }
}

private actor SystemAudioCaptureSpy: SystemAudioCapturing {
    private(set) var prepareCount = 0
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var running = false
    private let denyPermission: Bool
    private let silent: Bool
    private var handler: (@Sendable (TimestampedAudioChunk) -> Void)?
    init(denyPermission: Bool = false, silent: Bool = false) { self.denyPermission = denyPermission; self.silent = silent }
    func prepare() async throws {
        prepareCount += 1
        if denyPermission { throw SystemAudioCaptureError.permissionRequired }
    }
    func start(onChunk: @escaping @Sendable (TimestampedAudioChunk) -> Void) async throws {
        startCount += 1
        running = true
        handler = onChunk
        if silent { return }
        onChunk(TimestampedAudioChunk(startTime: 10 + 2 / 16_000.0, samples: [0.6, 0.6]))
    }
    func stop() {
        stopCount += 1
        if !silent { handler?(TimestampedAudioChunk(startTime: 10 + 4 / 16_000.0, samples: [0.6, 0.6])) }
        handler = nil
        running = false
    }
    func isRunning() -> Bool { running }
    func setRunning(_ value: Bool) { running = value }
}

private final class CapturedSampleSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Float] = []
    var samples: [Float] { lock.withLock { storage } }
    func append(_ values: [Float]) { lock.withLock { storage.append(contentsOf: values) } }
}
