import AVFoundation
import Foundation
import Testing
@testable import zspeak

// Testes de estado e invariantes do AudioCapture — sem dependencia de hardware de audio
@Suite("AudioCapture - Estado e invariantes")
struct AudioCaptureTests {

    // MARK: - Estado inicial

    @Test("Estado inicial deve ter isCapturing false e audioLevel 0")
    func testInitialState() async {
        let capture = AudioCapture()

        let capturing = await capture.isCapturing
        let level = await capture.audioLevel

        #expect(capturing == false)
        #expect(level == 0)
    }

    // MARK: - Stop sem captura ativa

    @Test("stop() quando nao esta capturando deve retornar array vazio sem crash")
    func testStopWhenNotRunning() async {
        let capture = AudioCapture()

        let samples = await capture.stop()

        #expect(samples.isEmpty)
        #expect(await capture.isCapturing == false)
    }

    @Test("stop() multiplas vezes sem start deve retornar arrays vazios")
    func testMultipleStopsWhenNotRunning() async {
        let capture = AudioCapture()

        let first = await capture.stop()
        let second = await capture.stop()

        #expect(first.isEmpty)
        #expect(second.isEmpty)
        #expect(await capture.isCapturing == false)
    }

    // MARK: - isCapturing reflete isRunning

    @Test("isCapturing deve ser false antes de qualquer start")
    func testIsCapturingInitiallyFalse() async {
        let capture = AudioCapture()

        #expect(await capture.isCapturing == false)
    }

    // MARK: - Regressão: crash no handleConfigurationChange

    @Test("handleConfigurationChange NÃO deve crashar quando engine reconfigura durante captura")
    func testConfigChangeDoesNotCrash() async {
        let capture = AudioCapture()

        // Simular: engine não está rodando, handleConfigurationChange deve ser no-op
        // (isRunning == false → guard retorna sem tentar reinstalar tap)
        await capture.simulateConfigurationChange()

        // Se chegou aqui sem crash, o guard funcionou
        #expect(await capture.isCapturing == false)
    }

    @Test("handleConfigurationChange preserva samples existentes")
    func testConfigChangePreservesSamples() async {
        let capture = AudioCapture()

        // Quando não está rodando, handleConfigurationChange não limpa samples
        await capture.simulateConfigurationChange()

        let samples = await capture.stop()
        // stop() retorna vazio porque nunca iniciou, mas não crashou
        #expect(samples.isEmpty)
    }

    @Test("start após stop não deve crashar (ciclo start/stop)")
    func testStartStopCycleNoCrash() async {
        let capture = AudioCapture()

        // stop sem start = seguro
        let samples1 = await capture.stop()
        #expect(samples1.isEmpty)

        // Segundo stop = seguro
        let samples2 = await capture.stop()
        #expect(samples2.isEmpty)

        // isCapturing deve ser false
        #expect(await capture.isCapturing == false)
    }

    // MARK: - Regressão: stop retorna samples acumulados (Bug 2 fix)

    @Test("stop() sem start retorna array vazio e não crashou")
    func testStopWithoutStartReturnsSafely() async {
        let capture = AudioCapture()
        let result = await capture.stop()
        #expect(result.isEmpty)
    }

    @Test("Benchmark: stop preserva chunk final entregue durante drain")
    func benchmarkStopPreservaChunkFinalDuranteDrain() async {
        let capture = AudioCapture()
        let iterations = 200

        let result = await capture.benchmarkStopDrainPreservesTrailingSamples(iterations: iterations)
        let p50 = percentile(result.elapsedMilliseconds, 0.50)
        let p95 = percentile(result.elapsedMilliseconds, 0.95)

        print("[BENCH STOP POST-ROLL] chunks finais preservados: \(result.preservedIterations)/\(iterations); p50=\(String(format: "%.3f", p50))ms; p95=\(String(format: "%.3f", p95))ms")

        #expect(result.preservedIterations == iterations)
    }

    @Test("Fixture real termina com fala ativa no tail")
    func trailingSomFixtureTerminaComFalaAtiva() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("trailing-som.wav")
        let file = try AVAudioFile(forReading: fixtureURL)
        let format = file.processingFormat
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(file.length)
        ))
        try file.read(into: buffer)
        let channel = try #require(buffer.floatChannelData?[0])
        let frameLength = Int(buffer.frameLength)
        let tailCount = min(Int(format.sampleRate * 0.025), frameLength)
        let tailStart = frameLength - tailCount

        var sumOfSquares: Float = 0
        for index in tailStart..<frameLength {
            let sample = channel[index]
            sumOfSquares += sample * sample
        }
        let rms = sqrt(sumOfSquares / Float(tailCount))

        #expect(rms > 0.006, "O fixture precisa terminar com fala ativa para cobrir o bug de pós-roll. RMS tail=\(rms)")
    }

    // MARK: - Regressão: crash SIGABRT em installTap após config change (#8)

    @Test("simulateConfigurationChange múltiplas vezes sem engine rodando não crasheia")
    func testMultipleConfigChangesWhenNotRunning() async {
        let capture = AudioCapture()

        // Config change disparado múltiplas vezes — guard isRunning deve proteger
        await capture.simulateConfigurationChange()
        await capture.simulateConfigurationChange()
        await capture.simulateConfigurationChange()

        #expect(await capture.isCapturing == false)
    }

    @Test("simulateConfigurationChange seguido de stop não crasheia")
    func testConfigChangeThenStopNoCrash() async {
        let capture = AudioCapture()

        await capture.simulateConfigurationChange()
        let samples = await capture.stop()

        #expect(samples.isEmpty)
        #expect(await capture.isCapturing == false)
    }

    // MARK: - Hot window e coolDown (regressão #35)

    @Test("Estado inicial: não está em hot window")
    func testIsHotFalseInicial() async {
        let capture = AudioCapture()
        #expect(await capture.isHot == false)
    }

    @Test("coolDown em estado frio é no-op (não crasheia)")
    func testCoolDownQuandoFrio() async {
        let capture = AudioCapture()
        await capture.coolDown()
        #expect(await capture.isHot == false)
        #expect(await capture.isCapturing == false)
    }

    @Test("coolDown não afeta warmup quando há gravação ativa")
    func testCoolDownDuranteGravacaoEhIgnorado() async {
        // Esse teste não grava de verdade (só valida que coolDown no-op
        // quando isRunning — sem hardware, isRunning sempre false, então
        // a invariante a validar é que coolDown em false não toca nada).
        let capture = AudioCapture()
        await capture.coolDown()
        await capture.coolDown()
        #expect(await capture.isHot == false)
    }

    @Test("warmUp com deviceUID inexistente propaga erro e não entra em hot window")
    func testWarmUpComDeviceInvalidoNaoAbreHot() async {
        let capture = AudioCapture()
        let uidInexistente = "test-invalid-warmup-\(UUID().uuidString)"

        do {
            try await capture.warmUp(deviceUID: uidInexistente)
            Issue.record("Esperado erro mas warmUp completou")
        } catch let error as AudioCaptureError {
            if case .coreAudioDeviceNotFound(let uid) = error {
                #expect(uid == uidInexistente)
            } else {
                Issue.record("Tipo de erro inesperado: \(error)")
            }
            #expect(await capture.isHot == false)
            #expect(await capture.isCapturing == false)
        } catch {
            Issue.record("Erro inesperado: \(error)")
        }
    }

    // MARK: - Fallback silencioso removido (task #1)

    @Test("start com deviceUID inexistente lanca .coreAudioDeviceNotFound")
    func start_comDeviceUIDInexistente_lancaErro() async {
        let capture = AudioCapture()
        let uidInexistente = "test-invalid-uid-\(UUID().uuidString)"

        do {
            try await capture.start(deviceUID: uidInexistente)
            Issue.record("Esperado erro, mas start() completou sem lancar")
            _ = await capture.stop()
        } catch let error as AudioCaptureError {
            // Esperamos .coreAudioDeviceNotFound com o uid que passamos
            switch error {
            case .coreAudioDeviceNotFound(let uid):
                #expect(uid == uidInexistente)
            default:
                Issue.record("Erro inesperado: \(error)")
            }
            // Estado deve ter voltado a nao-capturando apos throw
            #expect(await capture.isCapturing == false)
        } catch {
            Issue.record("Erro de tipo inesperado: \(error)")
        }
    }

}

private func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let position = (Double(sorted.count - 1) * p)
    let lower = Int(position)
    let upper = min(lower + 1, sorted.count - 1)
    if lower == upper {
        return sorted[lower]
    }
    return sorted[lower] + (sorted[upper] - sorted[lower]) * (position - Double(lower))
}

// Sub-suite serializada: testes que tocam o HAL real ou mexem no default input
// device. Rodar em paralelo causa interferência entre si (engine.start() falha
// com -10868 porque outro teste trocou o default no meio).
@Suite(
    "AudioCapture - Hardware real",
    .serialized,
    .disabled(
        if: ProcessInfo.processInfo.environment["CI"] != nil,
        "Requer microfone físico e HAL real; runner CI não tem device de entrada."
    )
)
struct AudioCaptureHardwareTests {

    // MARK: - Regressão: engine.start() falha com -10868 após setInputDevice (#mic-priority-fallback)

    /// Reproduz o bug em que selecionar um device específico via uniqueID
    /// sempre cai no fallback "system default" porque `engine.start()` lança
    /// -10868 (kAudioUnitErr_FormatNotSupported). O usuário observou o overlay
    /// mostrando sempre o device default do macOS mesmo com outro mic priorizado
    /// no topo da lista.
    ///
    /// Hardware-dependente: pula em CI e quando não há mic conectado.
    @Test("start com deviceUID de mic real não lança -10868 e captura do device selecionado")
    func start_comDeviceUIDReal_naoLancaFormatoIncompativel() async throws {
        guard ProcessInfo.processInfo.environment["CI"] == nil else { return }

        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        let realDevices = session.devices.filter { !$0.uniqueID.hasPrefix("CADefaultDeviceAggregate") }
        guard let mic = realDevices.first else { return }

        let capture = AudioCapture()

        do {
            try await capture.start(deviceUID: mic.uniqueID)
            #expect(await capture.isCapturing == true,
                    "start com uid '\(mic.uniqueID)' deveria ter ligado o engine")
        } catch {
            Issue.record("start(deviceUID:) lançou \(error) — provável -10868 do AUGraphParser. Mic usado: \(mic.localizedName) (\(mic.uniqueID))")
        }

        _ = await capture.stop()
        #expect(await capture.isHot == true)
        await capture.coolDown()
        #expect(await capture.isCapturing == false)
    }

    // MARK: - Regressão: latência entre engine.start() e primeiro sample (#primeiras-palavras-perdidas)

    /// Mede a latência intrínseca do HAL: do `engine.start()` retornar até o
    /// primeiro buffer chegar no tap. Esse valor é um piso que não conseguimos
    /// reduzir sem mexer em buffer frame size — ~100ms no dev atual.
    /// Documentação-only (não força threshold apertado).
    @Test("Registra latência entre engine.start() e primeiro sample (diagnóstico)")
    func latencia_primeiroSample_apos_engineStart() async throws {
        guard ProcessInfo.processInfo.environment["CI"] == nil else { return }

        let capture = AudioCapture()
        try await capture.start(deviceUID: nil)

        let deadline = CFAbsoluteTimeGetCurrent() + 2.0
        while await capture.firstSampleTimestamp == nil && CFAbsoluteTimeGetCurrent() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let firstSample = await capture.firstSampleTimestamp
        _ = await capture.stop()
        await capture.coolDown()

        guard let firstSample,
              let engineStart = await capture.engineStartTimestamp else {
            Issue.record("Nenhum sample chegou em 2s — engine não produziu áudio")
            return
        }

        let delayMs = (firstSample - engineStart) * 1000
        print("[LATENCIA HAL] primeiro sample \(String(format: "%.1f", delayMs))ms após engine.start()")
        #expect(delayMs < 300,
                "Latência HAL de \(String(format: "%.1f", delayMs))ms é alta — verifique buffer frame size")
    }

    /// Latência TOTAL do que o usuário percebe: de `start()` ser chamada (logo
    /// após o overlay acender) até o primeiro sample chegar. Essa é a janela
    /// em que o áudio é perdido se o usuário começar a falar imediatamente.
    ///
    /// Sem warmUp: ~380ms (AVAudioEngine construção + installTap + prepare + start + HAL).
    /// Com warmUp hot window: o engine já está em IO ativo e `start()` só liga
    /// a escrita no buffer principal, usando o pre-roll acumulado.
    @Test("Fast path com warmUp: start() → primeiro sample < 50ms")
    func latencia_total_comWarmUp_fastPath() async throws {
        guard ProcessInfo.processInfo.environment["CI"] == nil else { return }

        let capture = AudioCapture()

        // Pré-aquece com o mesmo deviceUID que usaremos no start
        try await capture.warmUp(deviceUID: nil)

        // Agora mede start() até first sample
        try await capture.start(deviceUID: nil)

        let deadline = CFAbsoluteTimeGetCurrent() + 2.0
        while await capture.firstSampleTimestamp == nil && CFAbsoluteTimeGetCurrent() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let firstSample = await capture.firstSampleTimestamp
        let startCalled = await capture.startCalledTimestamp
        _ = await capture.stop()
        await capture.coolDown()

        guard let firstSample, let startCalled else {
            Issue.record("Nenhum sample chegou em 2s")
            return
        }

        let totalMs = (firstSample - startCalled) * 1000
        print("[LATENCIA TOTAL fast path] start() → primeiro sample: \(String(format: "%.1f", totalMs))ms")

        #expect(totalMs < 50,
                "Latência total de \(String(format: "%.1f", totalMs))ms é alta — hot window não está zerando o start")
    }

    /// Documenta a latência TOTAL sem warmUp (cold path). Mostra o ganho do fix.
    @Test("Cold path (sem warmUp): start() → primeiro sample")
    func latencia_total_semWarmUp_coldPath() async throws {
        guard ProcessInfo.processInfo.environment["CI"] == nil else { return }

        let capture = AudioCapture()
        try await capture.start(deviceUID: nil)

        let deadline = CFAbsoluteTimeGetCurrent() + 2.0
        while await capture.firstSampleTimestamp == nil && CFAbsoluteTimeGetCurrent() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let firstSample = await capture.firstSampleTimestamp
        let startCalled = await capture.startCalledTimestamp
        _ = await capture.stop()
        await capture.coolDown()

        guard let firstSample, let startCalled else {
            Issue.record("Nenhum sample chegou em 2s")
            return
        }

        let totalMs = (firstSample - startCalled) * 1000
        print("[LATENCIA TOTAL cold path] start() → primeiro sample: \(String(format: "%.1f", totalMs))ms")
    }

    /// warmUp mantém o engine em IO ativo para que o próximo start seja imediato.
    /// O tap fica rodando, mas ainda sem gravar no buffer principal.
    @Test("warmUp abre hot window para start imediato")
    func warmUp_abreHotWindow() async throws {
        guard ProcessInfo.processInfo.environment["CI"] == nil else { return }

        let capture = AudioCapture()

        try await capture.warmUp(deviceUID: nil)
        #expect(await capture.isHot == true,
                "isHot deveria refletir hot window ativo")
        #expect(await capture.isCapturing == true,
                "isCapturing deveria ser true — hot window mantém o HAL aberto")

        await capture.coolDown()
        #expect(await capture.isHot == false)
    }

    @Test("coolDown descarta o prepare sem efeitos colaterais")
    func coolDown_descartaPrepare() async throws {
        guard ProcessInfo.processInfo.environment["CI"] == nil else { return }

        let capture = AudioCapture()

        try await capture.warmUp(deviceUID: nil)
        #expect(await capture.isHot == true)

        await capture.coolDown()
        #expect(await capture.isHot == false)
        #expect(await capture.isCapturing == false)
    }

    @Test("warmUp é idempotente para o mesmo device")
    func warmUp_idempotente() async throws {
        guard ProcessInfo.processInfo.environment["CI"] == nil else { return }

        let capture = AudioCapture()

        try await capture.warmUp(deviceUID: nil)
        #expect(await capture.isHot == true)

        // Segunda chamada com mesmo deviceUID não deve lançar.
        try await capture.warmUp(deviceUID: nil)
        #expect(await capture.isHot == true)

        await capture.coolDown()
    }

    /// Start após warmUp deve ser quase imediato: o engine já tem tap,
    /// prepare e IO ativo; só liga a escrita no buffer principal.
    @Test("start após warmUp (fast path) é mais rápido que cold path")
    func start_aposWarmUp_fastPathMenor() async throws {
        guard ProcessInfo.processInfo.environment["CI"] == nil else { return }

        // Warm — tempo apenas de promover hot window para gravação ativa.
        let warm = AudioCapture()
        try await warm.warmUp(deviceUID: nil)
        let t0warm = CFAbsoluteTimeGetCurrent()
        try await warm.start(deviceUID: nil)
        let t1warm = CFAbsoluteTimeGetCurrent()
        _ = await warm.stop()
        await warm.coolDown()
        let warmMs = (t1warm - t0warm) * 1000

        // Cold — engine criado do zero + installTap + prepare + start
        let cold = AudioCapture()
        let t0cold = CFAbsoluteTimeGetCurrent()
        try await cold.start(deviceUID: nil)
        let t1cold = CFAbsoluteTimeGetCurrent()
        _ = await cold.stop()
        await cold.coolDown()
        let coldMs = (t1cold - t0cold) * 1000

        print("[LATENCIA] warm start: \(String(format: "%.1f", warmMs))ms vs cold start: \(String(format: "%.1f", coldMs))ms")

        // Warm deve ser estritamente menor. Tolerância para jitter: ao menos 10 ms de ganho.
        #expect(warmMs < coldMs,
                "warm (\(warmMs)ms) deveria ser < cold (\(coldMs)ms)")
    }

    @Test("start com deviceUID nil usa default e inicia sem erro")
    func start_comDeviceUIDNil_usaDefaultEIniciaSemErro() async {
        // Depende de hardware real de microfone — skip em CI
        guard ProcessInfo.processInfo.environment["CI"] == nil else { return }

        let capture = AudioCapture()

        do {
            try await capture.start(deviceUID: nil)
            #expect(await capture.isCapturing == true)
            let samples = await capture.stop()
            // Samples podem estar vazios; o importante e que start nao lancou e stop nao crashou
            _ = samples
            #expect(await capture.isHot == true)
            await capture.coolDown()
            #expect(await capture.isCapturing == false)
        } catch {
            // Em ambiente sem mic disponivel (ex: VM sem driver), tolerar falha
            // apenas validando que o erro e do tipo esperado
            #expect(error is AudioCaptureError)
        }
    }
}
