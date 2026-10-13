import AVFoundation
import Foundation
import Testing
@testable import zspeak

@Suite("AudioCapture - Reconexão de microfone")
struct AudioCaptureDeviceChangeTests {
    private func makeCapture(_ factory: SimulatedCaptureEngineFactory, _ route: SimulatedInputRoute) -> AudioCapture {
        AudioCapture(
            engineFactory: { factory.makeEngine() },
            systemDefaultUIDProvider: { route.uid },
            now: { route.time }
        )
    }

    @Test("Conectar AirPods invalida o cache do microfone padrão sem reiniciar o app")
    func changedDefaultRebuildsCapture() async throws {
        let factory = SimulatedCaptureEngineFactory()
        let route = SimulatedInputRoute()
        let capture = makeCapture(factory, route)
        let firstSample = AtomicInt()

        try await capture.warmUp()
        let macBookEngine = factory.latest
        macBookEngine.emit(samples: [0.1, 0.1])
        route.uid = "airpods-pro-3"

        try await capture.start(onFirstSample: { firstSample.increment() })
        #expect(factory.count == 3)
        #expect(!macBookEngine.isRunning)
        #expect(firstSample.current == 0, "Não deve confirmar gravação com áudio do microfone anterior")

        factory.latest.emit(samples: [0.7, 0.7])
        try await waitUntil { firstSample.current == 1 }
        #expect(await capture.isReceivingAudio())
        let samples = await capture.stop()
        #expect(samples == [0.7, 0.7])
        await capture.coolDown()
    }

    @Test("Engine Bluetooth ainda ativo, mas sem áudio recente, usa captura nova")
    func stalePreRollRebuildsCapture() async throws {
        let factory = SimulatedCaptureEngineFactory()
        let route = SimulatedInputRoute()
        let capture = makeCapture(factory, route)
        let firstSample = AtomicInt()

        try await capture.warmUp()
        let oldEngine = factory.latest
        oldEngine.emit(samples: [0.1])
        route.time += 3

        try await capture.start(onFirstSample: { firstSample.increment() })
        #expect(factory.count == 3)
        #expect(!oldEngine.isRunning)
        #expect(firstSample.current == 0)
        #expect(await capture.isReceivingAudio() == false)

        factory.latest.emit(samples: [0.9])
        try await waitUntil { firstSample.current == 1 }
        let samples = await capture.stop()
        #expect(samples == [0.9])
        await capture.coolDown()
    }

    @Test("Pre-roll fresco do mesmo microfone mantém o início imediato")
    func healthyPreRollKeepsFastPath() async throws {
        let factory = SimulatedCaptureEngineFactory()
        let route = SimulatedInputRoute()
        let capture = makeCapture(factory, route)
        let firstSample = AtomicInt()

        try await capture.warmUp()
        factory.latest.emit(samples: [0.25, 0.5])
        try await capture.start(onFirstSample: { firstSample.increment() })

        #expect(factory.count == 2, "Não deve recriar um engine saudável")
        #expect(firstSample.current == 1)
        // Promover o pre-roll não pode gerar uma interrupção falsa antes do
        // próximo callback; o watchdog ainda respeita seus dois segundos.
        route.time += 1
        #expect(await capture.isReceivingAudio())
        route.time += 2
        #expect(await capture.isReceivingAudio() == false)
        let samples = await capture.stop()
        #expect(samples == [0.25, 0.5])
        await capture.coolDown()
    }

    @Test("warmUp refaz o engine após troca do padrão ou parada do HAL")
    func warmUpChecksDeviceAndEngine() async throws {
        let factory = SimulatedCaptureEngineFactory()
        let route = SimulatedInputRoute()
        let capture = makeCapture(factory, route)

        try await capture.warmUp()
        try await capture.warmUp()
        #expect(factory.count == 2)

        route.uid = "airpods-pro-3"
        try await capture.warmUp()
        #expect(factory.count == 3)

        factory.latest.stop()
        try await capture.warmUp()
        #expect(factory.count == 4)
        #expect(factory.latest.isRunning)
        await capture.coolDown()
    }

    @Test("Mudança de configuração invalida prewarm mesmo com engine marcado como ativo")
    func configurationChangeInvalidatesRunningPrewarm() async throws {
        let factory = SimulatedCaptureEngineFactory()
        let route = SimulatedInputRoute()
        let capture = makeCapture(factory, route)

        try await capture.warmUp()
        let oldEngine = factory.latest
        oldEngine.emit(samples: [0.2])
        oldEngine.notifyConfigurationChange()
        try await waitUntil { await capture.isHot == false }

        #expect(!oldEngine.isRunning)
        try await capture.start()
        #expect(factory.count == 3)
        #expect(await capture.firstSampleTimestamp == nil)
        _ = await capture.stop()
        await capture.coolDown()
    }

    @Test("Retirar AirPods durante captura preserva a fala e permite nova gravação")
    func interruptionPreservesAudioAndNextRecording() async throws {
        let factory = SimulatedCaptureEngineFactory()
        let route = SimulatedInputRoute()
        route.uid = "airpods-pro-3"
        let capture = makeCapture(factory, route)

        try await capture.start()
        factory.latest.emit(samples: [0.6, 0.8])
        try await waitUntil { await capture.firstSampleTimestamp != nil }
        factory.latest.stop()
        factory.latest.notifyConfigurationChange()
        try await waitUntil { await capture.isCapturing == false }

        #expect(await capture.isReceivingAudio() == false)
        let preserved = await capture.stop()
        #expect(preserved == [0.6, 0.8])

        route.uid = "macbook-microphone"
        try await capture.start()
        factory.latest.emit(samples: [0.3])
        try await waitUntil { await capture.firstSampleTimestamp != nil }
        #expect(await capture.isReceivingAudio())
        let next = await capture.stop()
        #expect(next == [0.3])
        await capture.coolDown()
    }

    @Test("Troca do padrão durante stop não rotula o engine antigo como o novo microfone")
    func routeChangeDuringStopDoesNotRelabelOldEngine() async throws {
        let factory = SimulatedCaptureEngineFactory()
        let route = SimulatedInputRoute()
        let capture = makeCapture(factory, route)
        try await capture.warmUp()
        let oldEngine = factory.latest
        oldEngine.emit(samples: [0.1])
        try await capture.start()

        route.uid = "airpods-pro-3"
        _ = await capture.stop()
        oldEngine.emit(samples: [0.2])
        try await capture.start()
        #expect(factory.count == 3)
        #expect(!oldEngine.isRunning)
        #expect(await capture.firstSampleTimestamp == nil)
        _ = await capture.stop()
        await capture.coolDown()
    }

    @Test("HAL parado durante preparo é invalidado e a próxima gravação funciona")
    func configurationChangeBeforeFirstSampleRecovers() async throws {
        let factory = SimulatedCaptureEngineFactory()
        let route = SimulatedInputRoute()
        let capture = makeCapture(factory, route)
        try await capture.start()
        factory.latest.stop()
        factory.latest.notifyConfigurationChange()
        try await waitUntil { await capture.isCapturing == false }
        _ = await capture.stop()

        try await capture.start()
        factory.latest.emit(samples: [0.4])
        try await waitUntil { await capture.firstSampleTimestamp != nil }
        #expect(await capture.isReceivingAudio())
        _ = await capture.stop()
        await capture.coolDown()
    }

    @Test("Restaurar input temporário preserva a escolha nova do usuário/macOS")
    func restorationPreservesExternalRouteChange() {
        #expect(AudioCapture.restorationDeviceID(original: 10, overridden: 20, current: 20) == 10)
        #expect(AudioCapture.restorationDeviceID(original: 10, overridden: 20, current: 30) == nil)
        #expect(AudioCapture.restorationDeviceID(original: 10, overridden: 20, current: nil) == nil)
        #expect(AudioCapture.restorationDeviceID(original: 0, overridden: 20, current: 20) == nil)
    }

    @Test("Tap vazio mantém watchdog armado até chegarem samples válidos")
    func emptyTapDoesNotConfirmRecording() async throws {
        let factory = SimulatedCaptureEngineFactory()
        let route = SimulatedInputRoute()
        let capture = makeCapture(factory, route)
        let firstSample = AtomicInt()

        try await capture.start(onFirstSample: { firstSample.increment() })
        factory.latest.emit(samples: [])
        #expect(await capture.firstSampleTimestamp == nil)
        #expect(firstSample.current == 0)

        factory.latest.emit(samples: [0]) // Silêncio é um buffer válido.
        try await waitUntil { firstSample.current == 1 }
        #expect(await capture.isReceivingAudio())
        route.time += 3
        #expect(await capture.isReceivingAudio() == false)
        _ = await capture.stop()
        await capture.coolDown()
    }

    @Test("Captura com timestamp não duplica samples e volta ao microfone normal após stop")
    func timedCaptureReturnsToNormalMicrophoneMode() async throws {
        let factory = SimulatedCaptureEngineFactory()
        let route = SimulatedInputRoute()
        let capture = makeCapture(factory, route)
        let received = AtomicInt()
        try await capture.warmUp()
        factory.latest.emit(samples: [0.1])
        try await capture.startTimestamped(deviceUID: nil, onFirstSample: nil) { chunk in
            if chunk.samples == [0.6, 0.8], chunk.startTime.isFinite { received.increment() }
        }
        #expect(factory.count == 3, "Tap temporizado precisa de uma sessão própria")
        factory.latest.emit(samples: [0.6, 0.8])
        #expect(received.current == 1)
        #expect(await capture.isReceivingAudio())
        let rawDuplicate = await capture.stop()
        #expect(rawDuplicate.isEmpty, "O áudio completo fica somente na mistura")
        #expect(await capture.isHot == false)

        try await capture.start()
        factory.latest.emit(samples: [0.3, 0.4])
        try await waitUntil { await capture.firstSampleTimestamp != nil }
        let plain = await capture.stop()
        #expect(plain == [0.3, 0.4])
        await capture.coolDown()
    }
}

/// Simula a rota e o relógio sem mudar dispositivos ou preferências do Mac.
private final class SimulatedInputRoute: @unchecked Sendable {
    private let lock = NSLock()
    private var storedUID: String? = "macbook-microphone"
    private var storedTime: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()

    var uid: String? {
        get { lock.withLock { storedUID } }
        set { lock.withLock { storedUID = newValue } }
    }
    var time: CFAbsoluteTime {
        get { lock.withLock { storedTime } }
        set { lock.withLock { storedTime = newValue } }
    }
}

private final class SimulatedCaptureEngineFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var engines: [SimulatedCaptureEngine] = []

    var count: Int { lock.withLock { engines.count } }
    var latest: SimulatedCaptureEngine { lock.withLock { engines.last! } }

    func makeEngine() -> any AudioCaptureEngine {
        let engine = SimulatedCaptureEngine()
        lock.withLock { engines.append(engine) }
        return engine
    }
}

private final class SimulatedCaptureEngine: NSObject, AudioCaptureEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var running = false
    private var tap: AVAudioNodeTapBlock?

    var isRunning: Bool { lock.withLock { running } }
    var inputFormat: AVAudioFormat { AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)! }
    var configurationChangeSource: AnyObject { self }
    func setVoiceProcessingEnabled(_ enabled: Bool) throws {}
    func installInputTap(_ block: @escaping AVAudioNodeTapBlock) { lock.withLock { tap = block } }
    func removeInputTap() { lock.withLock { tap = nil } }
    func prepare() {}
    func start() throws { lock.withLock { running = true } }
    func stop() { lock.withLock { running = false } }

    func emit(samples: [Float]) {
        guard let callback = lock.withLock({ tap }) else { return }
        let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(max(1, samples.count)))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for (index, sample) in samples.enumerated() { buffer.floatChannelData![0][index] = sample }
        callback(buffer, AVAudioTime(sampleTime: 0, atRate: 16_000))
    }

    func notifyConfigurationChange() {
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: self)
    }
}
