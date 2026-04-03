import Testing
@testable import zspeak

// Testes de logica de estado do AppState — sem dependencias de audio/microfone
@MainActor
@Suite("AppState - Logica de estado")
struct AppStateTests {

    // MARK: - Estado inicial

    @Test("Estado inicial deve ser idle com modelo e acessibilidade desativados")
    func testInitialState() {
        let appState = AppState()

        #expect(appState.state == .idle)
        #expect(appState.isModelReady == false)
        #expect(appState.accessibilityGranted == false)
        #expect(appState.lastTranscription == "")
        #expect(appState.errorMessage == nil)
        #expect(appState.audioLevel == 0)
    }

    // MARK: - Toggle sem pre-requisitos

    @Test("Toggle sem modelo pronto deve setar errorMessage")
    func testToggleRecordingWithoutModel() {
        let appState = AppState()
        appState.isModelReady = false
        appState.accessibilityGranted = true

        appState.toggleRecording()

        #expect(appState.state == .idle)
        #expect(appState.errorMessage != nil)
        #expect(appState.errorMessage?.contains("carregando") == true)
    }

    @Test("Toggle com modelo pronto mas sem acessibilidade deve setar errorMessage")
    func testToggleRecordingWithoutAccessibility() {
        let appState = AppState()
        appState.isModelReady = true
        appState.accessibilityGranted = false

        appState.toggleRecording()

        #expect(appState.state == .idle)
        #expect(appState.errorMessage != nil)
        #expect(appState.errorMessage?.contains("Acessibilidade") == true)
    }

    @Test("Toggle sem modelo nem acessibilidade nao deve mudar state")
    func testToggleRecordingBlocked() {
        let appState = AppState()
        appState.isModelReady = false
        appState.accessibilityGranted = false

        appState.toggleRecording()

        #expect(appState.state == .idle)
        #expect(appState.errorMessage != nil)
    }

    // MARK: - Metodos condicionais

    @Test("startRecordingIfIdle quando nao esta idle nao deve mudar state")
    func testStartRecordingIfIdleWhenNotIdle() {
        let appState = AppState()
        appState.isModelReady = true
        appState.accessibilityGranted = true

        // Forcar state para processing para testar o guard
        appState.state = .processing

        appState.startRecordingIfIdle()

        #expect(appState.state == .processing)
    }

    @Test("stopRecordingIfActive quando nao esta gravando nao deve mudar state")
    func testStopRecordingIfActiveWhenNotRecording() {
        let appState = AppState()

        // State idle — stopRecordingIfActive nao deve fazer nada
        appState.stopRecordingIfActive()

        #expect(appState.state == .idle)

        // State processing — tambem nao deve fazer nada
        appState.state = .processing
        appState.stopRecordingIfActive()

        #expect(appState.state == .processing)
    }

    @Test("cancelRecording quando idle nao deve fazer nada")
    func testCancelRecordingWhenIdle() {
        let appState = AppState()

        appState.cancelRecording()

        #expect(appState.state == .idle)
        #expect(appState.errorMessage == nil)
    }

    // MARK: - Toggle durante processing

    @Test("Toggle durante processing deve ser ignorado")
    func testToggleDuringProcessing() {
        let appState = AppState()
        appState.state = .processing

        appState.toggleRecording()

        #expect(appState.state == .processing)
    }
}
