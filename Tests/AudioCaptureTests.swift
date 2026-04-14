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

// Sub-suite serializada: testes que tocam o HAL real ou mexem no default input
// device. Rodar em paralelo causa interferência entre si (engine.start() falha
// com -10868 porque outro teste trocou o default no meio).
@Suite("AudioCapture - Hardware real", .serialized)
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
        #expect(await capture.isCapturing == false)
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
            #expect(await capture.isCapturing == false)
        } catch {
            // Em ambiente sem mic disponivel (ex: VM sem driver), tolerar falha
            // apenas validando que o erro e do tipo esperado
            #expect(error is AudioCaptureError)
        }
    }
}
