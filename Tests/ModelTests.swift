import Testing
@testable import zspeak

// Testes de estado e erros do Transcriber
// SEM inicializacao de modelos reais (evita download de ~500MB)
@Suite("Models - Transcriber")
struct ModelTests {

    // MARK: - Transcriber estado inicial

    @Test("Transcriber deve ter isReady false antes de initialize")
    func testTranscriberInitialState() async {
        let transcriber = Transcriber()

        let ready = await transcriber.isReady
        #expect(ready == false)
    }

    // MARK: - Transcriber erro sem inicializacao

    @Test("Transcriber.transcribe sem initialize deve lancar notInitialized")
    func testTranscriberThrowsWhenNotInitialized() async {
        let transcriber = Transcriber()
        let samples: [Float] = [0.0, 0.1, -0.1, 0.2]

        await #expect(throws: Transcriber.TranscriberError.notInitialized) {
            try await transcriber.transcribe(samples)
        }
    }

    // MARK: - Transcriber erro com samples vazios

    @Test("Transcriber.transcribe com samples vazios sem initialize deve lancar notInitialized")
    func testTranscriberEmptySamplesThrows() async {
        let transcriber = Transcriber()

        await #expect(throws: Transcriber.TranscriberError.notInitialized) {
            try await transcriber.transcribe([])
        }
    }

    // MARK: - TranscriberError descricao

    @Test("TranscriberError.notInitialized deve ter errorDescription nao nil")
    func testTranscriberErrorDescription() {
        let error = Transcriber.TranscriberError.notInitialized

        #expect(error.errorDescription != nil)
        #expect(error.errorDescription?.isEmpty == false)
    }
}
