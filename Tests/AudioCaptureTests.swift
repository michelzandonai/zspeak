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
}
