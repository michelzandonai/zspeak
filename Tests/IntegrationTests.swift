import Testing
@testable import zspeak

/// Testes de integração da máquina de estados do AppState.
/// Verificam fluxos completos e sequências de operações — não testam áudio nem transcrição.
@MainActor
@Suite("AppState - Integração da máquina de estados")
struct IntegrationTests {

    // MARK: - Helpers

    /// Cria AppState configurado com modelo pronto e acessibilidade concedida
    private func makeReadyAppState() -> AppState {
        let appState = AppState()
        appState.isModelReady = true
        appState.accessibilityGranted = true
        return appState
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

    @Test("toggleRecording com modelo ok mas sem acessibilidade deve bloquear e setar errorMessage")
    func testAppStateBlocksRecordingWithoutAccessibility() {
        let appState = AppState()
        appState.isModelReady = true
        appState.accessibilityGranted = false

        appState.toggleRecording()

        #expect(appState.state == .idle, "Deve permanecer idle sem acessibilidade")
        #expect(appState.errorMessage != nil, "Deve ter mensagem de erro")
        #expect(appState.errorMessage?.contains("Acessibilidade") == true)

        // startRecordingIfIdle também deve bloquear
        appState.errorMessage = nil
        appState.startRecordingIfIdle()
        #expect(appState.state == .idle)
        #expect(appState.errorMessage?.contains("Acessibilidade") == true)
    }

    // MARK: - 3. Transições de estado

    @Test("Fluxo idle → recording quando pré-requisitos atendidos")
    func testStateTransitions() {
        let appState = makeReadyAppState()

        #expect(appState.state == .idle, "Estado inicial deve ser idle")
        #expect(appState.errorMessage == nil)

        // Toggle deve transicionar para recording
        appState.toggleRecording()

        #expect(appState.state == .recording, "Deve transicionar para recording")
        #expect(appState.errorMessage == nil, "Não deve ter erro quando pré-requisitos ok")
    }

    @Test("startRecordingIfIdle transiciona para recording quando idle e pré-requisitos ok")
    func testStartRecordingIfIdleTransitions() {
        let appState = makeReadyAppState()

        appState.startRecordingIfIdle()

        #expect(appState.state == .recording)
        #expect(appState.errorMessage == nil)
    }

    @Test("startRecordingIfIdle não faz nada quando já está recording")
    func testStartRecordingIfIdleWhenRecording() {
        let appState = makeReadyAppState()
        appState.toggleRecording()
        #expect(appState.state == .recording)

        // Segunda chamada não deve causar erro
        appState.startRecordingIfIdle()
        #expect(appState.state == .recording)
    }

    @Test("startRecordingIfIdle não faz nada quando está processing")
    func testStartRecordingIfIdleWhenProcessing() {
        let appState = makeReadyAppState()
        appState.state = .processing

        appState.startRecordingIfIdle()
        #expect(appState.state == .processing)
    }

    // MARK: - 4. Cancelamento durante gravação

    @Test("cancelRecording durante recording deve voltar para idle")
    func testCancelRecordingFromRecording() async throws {
        let appState = makeReadyAppState()

        // Inicia gravação
        appState.toggleRecording()
        #expect(appState.state == .recording)

        // Cancela
        appState.cancelRecording()

        // cancelRecording usa Task interno, aguardar a transição
        try await waitUntilOnMain(timeout: .seconds(3)) {
            appState.state == .idle
        }

        #expect(appState.state == .idle, "Deve voltar para idle após cancelamento")
        #expect(appState.errorMessage == nil, "Cancelamento não deve gerar erro")
        #expect(appState.audioLevel == 0, "Nível de áudio deve zerar após cancelamento")
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

    @Test("Sequência completa: bloqueia → libera modelo → bloqueia → libera acessibilidade → grava")
    func testFullPrerequisiteSequence() {
        let appState = AppState()

        // Sem nada: bloqueia por modelo
        appState.toggleRecording()
        #expect(appState.state == .idle)
        #expect(appState.errorMessage?.contains("carregando") == true)

        // Modelo pronto, sem acessibilidade: bloqueia por acessibilidade
        appState.isModelReady = true
        appState.errorMessage = nil
        appState.toggleRecording()
        #expect(appState.state == .idle)
        #expect(appState.errorMessage?.contains("Acessibilidade") == true)

        // Tudo pronto: grava
        appState.accessibilityGranted = true
        appState.errorMessage = nil
        appState.toggleRecording()
        #expect(appState.state == .recording)
        #expect(appState.errorMessage == nil)
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
    func testErrorMessageClearedOnSuccessfulStart() {
        let appState = makeReadyAppState()
        appState.errorMessage = "Erro anterior qualquer"

        appState.toggleRecording()

        #expect(appState.state == .recording)
        #expect(appState.errorMessage == nil, "Erro anterior deve ser limpo ao gravar com sucesso")
    }

    // MARK: - Regressão: Race condition hold mode (Bug 1 fix)

    @Test("stopRecording imediatamente após startRecording não deve crashar (hold mode rápido)")
    func testImmediateStopAfterStart() async throws {
        let appState = makeReadyAppState()

        // Simula hold mode: key-down → key-up imediato
        appState.startRecordingIfIdle()
        #expect(appState.state == .recording)

        appState.stopRecordingIfActive()

        // stopRecording muda state para .processing sincronamente
        // O Task interno aguarda recordingTask (que acessa hardware real)
        // Em ambiente de teste, o estado final pode ser .idle ou .processing
        // dependendo da disponibilidade do microfone — o importante é NÃO crashar
        try await waitUntilOnMain(timeout: .seconds(3)) {
            appState.state == .idle
        }

        // Aceita .idle (mic disponível) ou .processing (mic indisponível, task pendente)
        let validStates: [AppState.RecordingState] = [.idle, .processing]
        #expect(validStates.contains(appState.state), "Deve estar em idle ou processing, não recording")
    }

    @Test("cancelRecording imediatamente após startRecording não deve crashar")
    func testImmediateCancelAfterStart() async throws {
        let appState = makeReadyAppState()

        appState.startRecordingIfIdle()
        #expect(appState.state == .recording)

        appState.cancelRecording()

        // cancelRecording seta state = .idle SINCRONAMENTE (antes do Task)
        #expect(appState.state == .idle, "Deve voltar para idle imediatamente após cancel")
    }

    @Test("Múltiplos start/stop rápidos (hold mode spam) não devem crashar")
    func testRapidStartStopCycles() async throws {
        let appState = makeReadyAppState()

        for _ in 0..<5 {
            appState.startRecordingIfIdle()
            // Só chama stop se realmente entrou em recording
            if appState.state == .recording {
                appState.stopRecordingIfActive()
            }
        }

        // Aguarda resolução (com tolerância para hardware indisponível)
        try await waitUntilOnMain(timeout: .seconds(3)) {
            appState.state == .idle
        }

        let validStates: [AppState.RecordingState] = [.idle, .processing]
        #expect(validStates.contains(appState.state), "Deve terminar em estado estável")
    }
}
