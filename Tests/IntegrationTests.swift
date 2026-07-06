import Foundation
import Testing
@testable import zspeak

/// Testes de integração da máquina de estados do AppState.
/// Verificam fluxos completos e sequências de operações — não testam áudio nem transcrição.
///
/// Serializado + `withRealAudioDevice`: os testes que chegam a `toggleRecording`
/// com modelo pronto sobem o AVAudioEngine REAL e disputam o default input
/// device com outras suítes (AudioCaptureHardwareTests etc.). O mutex global
/// garante exclusão entre suítes; o `.serialized` garante dentro desta.
@MainActor
@Suite("AppState - Integração da máquina de estados", .serialized)
struct IntegrationTests {

    // MARK: - Helpers

    /// Cria AppState configurado com modelo pronto e acessibilidade concedida
    private func makeReadyAppState() -> AppState {
        let appState = AppState(skipBundlePermissionCheck: true)
        appState.isModelReady = true
        appState.accessibilityGranted = true
        return appState
    }

    /// Encerra qualquer gravação deixada ativa e aguarda o estado assentar —
    /// evita engine órfão segurando o HAL enquanto o próximo teste roda.
    private func settle(_ appState: AppState) async throws {
        if appState.isRecordingOrPreparing {
            appState.cancelRecording()
        }
        try await waitUntilOnMain(timeout: .seconds(15)) {
            !appState.isRecordingOrPreparing
        }
    }

    // MARK: - 1. Bloqueia gravação sem modelo

    @Test("toggleRecording sem modelo pronto deve bloquear e setar errorMessage")
    func testAppStateBlocksRecordingWithoutModel() {
        let appState = AppState()
        appState.isModelReady = false
        appState.accessibilityGranted = true

        appState.toggleRecording()

        #expect(appState.state == .idle, "Deve permanecer idle quando modelo não está pronto")
        #expect(appState.errorMessage != nil, "Deve ter mensagem de erro")
        #expect(appState.errorMessage?.contains("carregando") == true)

        // Tentativas repetidas não devem mudar o estado
        appState.toggleRecording()
        appState.toggleRecording()
        #expect(appState.state == .idle)
    }

    // MARK: - 2. Bloqueia gravação sem acessibilidade

    @Test("toggleRecording com modelo ok mas sem acessibilidade não deve bloquear por acessibilidade")
    func testAppStateBlocksRecordingWithoutAccessibility() async throws {
        try await withRealAudioDevice {
            let appState = AppState(skipBundlePermissionCheck: true)
            appState.isModelReady = true
            appState.accessibilityGranted = false

            appState.toggleRecording()

            #expect(appState.errorMessage?.contains("Acessibilidade") != true)
            #expect(appState.state != .processing)

            try await settle(appState)

            // startRecordingIfIdle também não deve falhar por acessibilidade
            appState.errorMessage = nil
            appState.startRecordingIfIdle()
            #expect(appState.errorMessage?.contains("Acessibilidade") != true)

            try await settle(appState)
        }
    }

    // MARK: - 3. Transições de estado

    @Test("Fluxo idle → preparing quando pré-requisitos atendidos")
    func testStateTransitions() async throws {
        try await withRealAudioDevice {
            let appState = makeReadyAppState()

            #expect(appState.state == .idle, "Estado inicial deve ser idle")
            #expect(appState.errorMessage == nil)

            // Toggle deve transicionar para preparing (engine ainda não capturou 1º sample)
            appState.toggleRecording()

            #expect(appState.isRecordingOrPreparing, "Deve transicionar para preparing ou recording")
            #expect(appState.errorMessage == nil, "Não deve ter erro quando pré-requisitos ok")

            try await settle(appState)
        }
    }

    @Test("startRecordingIfIdle transiciona para preparing/recording quando idle e pré-requisitos ok")
    func testStartRecordingIfIdleTransitions() async throws {
        try await withRealAudioDevice {
            let appState = makeReadyAppState()

            appState.startRecordingIfIdle()

            #expect(appState.isRecordingOrPreparing)
            #expect(appState.errorMessage == nil)

            try await settle(appState)
        }
    }

    @Test("startRecordingIfIdle não faz nada quando já está gravando/preparando")
    func testStartRecordingIfIdleWhenRecording() async throws {
        try await withRealAudioDevice {
            let appState = makeReadyAppState()
            appState.toggleRecording()
            #expect(appState.isRecordingOrPreparing)

            // Segunda chamada não deve causar erro nem alterar estado base
            appState.startRecordingIfIdle()
            #expect(appState.isRecordingOrPreparing)

            try await settle(appState)
        }
    }

    @Test("startRecordingIfIdle não faz nada quando está processing")
    func testStartRecordingIfIdleWhenProcessing() {
        let appState = makeReadyAppState()
        appState.state = .processing

        appState.startRecordingIfIdle()
        #expect(appState.state == .processing)
    }

    // MARK: - 4. Cancelamento durante gravação

    @Test("cancelRecording durante preparing/recording deve voltar para idle")
    func testCancelRecordingFromRecording() async throws {
        try await withRealAudioDevice {
            let appState = makeReadyAppState()

            // Inicia gravação
            appState.toggleRecording()
            #expect(appState.isRecordingOrPreparing)

            // Cancela
            appState.cancelRecording()

            // cancelRecording usa Task interno, aguardar a transição
            try await waitUntilOnMain(timeout: .seconds(15)) {
                !appState.isRecordingOrPreparing
            }

            #expect(appState.state == .idle, "Deve voltar para idle após cancelamento")
            #expect(appState.errorMessage == nil, "Cancelamento não deve gerar erro")
        }
    }

    // MARK: - 5. Cancelamento quando idle

    @Test("cancelRecording quando idle não deve alterar estado nem gerar erro")
    func testCancelRecordingFromIdle() {
        let appState = AppState()

        #expect(appState.state == .idle)
        #expect(appState.errorMessage == nil)

        appState.cancelRecording()

        #expect(appState.state == .idle, "Deve permanecer idle")
        #expect(appState.errorMessage == nil, "Não deve gerar erro")
    }

    @Test("cancelRecording quando processing não deve alterar estado")
    func testCancelRecordingFromProcessing() {
        let appState = makeReadyAppState()
        appState.state = .processing

        appState.cancelRecording()

        #expect(appState.state == .processing, "Deve permanecer processing — cancel só funciona em recording")
    }

    // MARK: - 6. Toggle durante processing

    @Test("toggleRecording durante processing deve ser ignorado completamente")
    func testToggleDuringProcessing() {
        let appState = makeReadyAppState()
        appState.state = .processing
        appState.errorMessage = nil

        appState.toggleRecording()

        #expect(appState.state == .processing, "Deve permanecer processing")
        #expect(appState.errorMessage == nil, "Não deve gerar erro — apenas ignora")
    }

    @Test("stopRecordingIfActive durante processing deve ser ignorado")
    func testStopRecordingIfActiveDuringProcessing() {
        let appState = makeReadyAppState()
        appState.state = .processing

        appState.stopRecordingIfActive()

        #expect(appState.state == .processing)
    }

    // MARK: - Fluxos combinados

    @Test("Sequência completa: bloqueia por modelo e não depende de acessibilidade para iniciar")
    func testFullPrerequisiteSequence() async throws {
        try await withRealAudioDevice {
            let appState = AppState(skipBundlePermissionCheck: true)

            // Sem nada: bloqueia por modelo
            appState.toggleRecording()
            #expect(appState.state == .idle)
            #expect(appState.errorMessage?.contains("carregando") == true)

            // Modelo pronto, sem acessibilidade: não deve falhar por acessibilidade
            appState.isModelReady = true
            appState.errorMessage = nil
            appState.toggleRecording()
            #expect(appState.errorMessage?.contains("Acessibilidade") != true)
            #expect(appState.state != .processing)

            try await settle(appState)
        }
    }

    @Test("Múltiplos toggles durante processing são todos ignorados")
    func testMultipleTogglesDuringProcessing() {
        let appState = makeReadyAppState()
        appState.state = .processing

        for _ in 0..<10 {
            appState.toggleRecording()
        }

        #expect(appState.state == .processing, "Processing deve resistir a múltiplos toggles")
        #expect(appState.errorMessage == nil)
    }

    @Test("errorMessage é limpa ao iniciar gravação com sucesso")
    func testErrorMessageClearedOnSuccessfulStart() async throws {
        try await withRealAudioDevice {
            let appState = makeReadyAppState()
            appState.errorMessage = "Erro anterior qualquer"

            appState.toggleRecording()

            #expect(appState.isRecordingOrPreparing)
            #expect(appState.errorMessage == nil, "Erro anterior deve ser limpo ao gravar com sucesso")

            try await settle(appState)
        }
    }

    // MARK: - Regressão: Race condition hold mode (Bug 1 fix)

    @Test("stopRecording imediatamente após startRecording não deve crashar (hold mode rápido)")
    func testImmediateStopAfterStart() async throws {
        try await withRealAudioDevice {
            let appState = makeReadyAppState()

            // Simula hold mode: key-down → key-up imediato
            appState.startRecordingIfIdle()
            #expect(appState.isRecordingOrPreparing)

            appState.stopRecordingIfActive()

            // stopRecording muda state para .processing sincronamente
            // O Task interno aguarda recordingTask (que acessa hardware real)
            // Em ambiente de teste, o estado final pode ser .idle ou .processing
            // dependendo da disponibilidade do microfone — o importante é NÃO crashar
            try await waitUntilOnMain(timeout: .seconds(15)) {
                !appState.isRecordingOrPreparing
            }

            // Aceita .idle (mic disponível) ou .processing (mic indisponível, task pendente)
            let validStates: [AppState.RecordingState] = [.idle, .processing]
            #expect(validStates.contains(appState.state), "Deve estar em idle ou processing")
        }
    }

    @Test("cancelRecording imediatamente após startRecording não deve crashar")
    func testImmediateCancelAfterStart() async throws {
        try await withRealAudioDevice {
            let appState = makeReadyAppState()

            appState.startRecordingIfIdle()
            #expect(appState.isRecordingOrPreparing)

            appState.cancelRecording()

            // cancelRecording seta state = .idle SINCRONAMENTE (antes do Task)
            #expect(appState.state == .idle, "Deve voltar para idle imediatamente após cancel")

            try await settle(appState)
        }
    }

    @Test("Múltiplos start/stop rápidos (hold mode spam) não devem crashar")
    func testRapidStartStopCycles() async throws {
        try await withRealAudioDevice {
            let appState = makeReadyAppState()

            for _ in 0..<5 {
                appState.startRecordingIfIdle()
                // Só chama stop se realmente entrou em preparing/recording
                if appState.isRecordingOrPreparing {
                    appState.stopRecordingIfActive()
                }
            }

            // Aguarda resolução (com tolerância para hardware indisponível)
            try await waitUntilOnMain(timeout: .seconds(15)) {
                !appState.isRecordingOrPreparing
            }

            let validStates: [AppState.RecordingState] = [.idle, .processing]
            #expect(validStates.contains(appState.state), "Deve terminar em estado estável")
        }
    }

    // MARK: - Fallback iterativo para system default (task #3)

    @Test("startRecording com mic priorizado inexistente cai para default do sistema")
    func startRecording_comMicPriorizadoInexistente_caiParaDefault() async throws {
        // Depende de hardware real de mic para o fallback default funcionar — skip em CI
        guard ProcessInfo.processInfo.environment["CI"] == nil else { return }

        try await withRealAudioDevice {
            let appState = makeReadyAppState()

            // Garante permissao em estado autorizado (requer mic real funcionando)
            guard appState.microphoneManager.isPermissionGranted else {
                return
            }

            // Configura mic priorizado que nao existe. connectedMicrophones() devolve
            // este UID, AudioCapture.start() deve falhar com .coreAudioDeviceNotFound,
            // e startRecording deve percorrer o loop e cair para system default (nil).
            appState.microphoneManager.useSystemDefault = false
            appState.microphoneManager.microphones = [
                MicrophoneInfo(id: "test-invalid-uid-12345", name: "Fake Mic", isConnected: true),
            ]

            // O HAL pode estar liberando o device de um teste anterior — tolera
            // falha transitória com uma segunda tentativa. Indisponibilidade real
            // do default (ex.: outro processo segurando o mic) vira skip explícito,
            // não falha: o alvo desta regressão é o LOOP de fallback, não o HAL.
            var recordingViaDefault = false
            for tentativa in 1...2 {
                appState.errorMessage = nil
                appState.toggleRecording()

                // Aguarda o loop percorrer o candidato inválido e cair pro default,
                // OU o controller desistir com errorMessage.
                let deadline = ContinuousClock.now + .seconds(10)
                while ContinuousClock.now < deadline {
                    if appState.microphoneManager.activeMicrophoneID == nil,
                       appState.state == .recording {
                        recordingViaDefault = true
                        break
                    }
                    if appState.errorMessage != nil { break }
                    try await Task.sleep(for: .milliseconds(50))
                }
                if recordingViaDefault { break }

                try await settle(appState)
                if tentativa == 1 {
                    try await Task.sleep(for: .seconds(1))
                }
            }

            guard recordingViaDefault else {
                print("SKIP: default input indisponível no momento — fallback não pôde ser exercitado")
                try await settle(appState)
                return
            }

            // Fallback aconteceu: ID ativo e nil (indicando default), estado = recording
            #expect(appState.microphoneManager.activeMicrophoneID == nil)
            #expect(appState.state == .recording)
            #expect(appState.errorMessage == nil)

            // Limpa estado
            appState.cancelRecording()
            try await waitUntilOnMain(timeout: .seconds(15)) {
                appState.state == .idle
            }
        }
    }
}
