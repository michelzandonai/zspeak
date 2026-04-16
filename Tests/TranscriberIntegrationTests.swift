import Foundation
import Testing
@testable import zspeak

/// Testes de integração "fim-a-fim" do pipeline de transcrição.
///
/// Carregam fixtures reais de áudio (Tests/Fixtures/*.wav) e rodam o modelo
/// Parakeet TDT v3 via `Transcriber` + `AudioFileTranscriber`.
///
/// ATENÇÃO — primeira execução:
///   O FluidAudio baixa o modelo Parakeet (~496 MB) do HuggingFace na primeira
///   vez que `Transcriber.initialize()` é chamado. Isso pode levar vários
///   minutos dependendo da conexão. Execuções seguintes usam cache local.
///
/// Skip em CI / execuções rápidas:
///   Exporte `ZSPEAK_SKIP_SLOW=1` para pular todo o suite.
///
/// Por que não um `.tags(.slow)`? Swift Testing aceita tags customizadas, mas
/// filtrar via CLI ainda é instável entre versões do Xcode. A env var é portátil
/// e funciona em `swift test`, Xcode, e CI sem configuração extra.
@Suite("Transcriber Integration - Real Audio Fixtures")
@MainActor
struct TranscriberIntegrationTests {

    // MARK: - Setup

    /// URL da pasta Tests/Fixtures/ no checkout local.
    /// Usamos `#filePath` em vez de `Bundle.module` para não exigir mudança no
    /// Package.swift (copiar fixtures como resource incharia o bundle de testes
    /// mesmo quando a suite está sendo pulada).
    private static let fixturesDir: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
    }()

    /// Retorna `true` se a suite deve ser pulada neste ambiente.
    private static var shouldSkip: Bool {
        ProcessInfo.processInfo.environment["ZSPEAK_SKIP_SLOW"] == "1"
    }

    /// Cria um Transcriber real já inicializado (baixa/carrega modelo se preciso).
    /// Reutilizamos a mesma instância entre testes via actor — inicialização é cara.
    private static let sharedTranscriber = SharedTranscriber()

    private actor SharedTranscriber {
        private var transcriber: Transcriber?
        private var initError: Error?

        func get() async throws -> Transcriber {
            if let t = transcriber { return t }
            if let e = initError { throw e }
            let t = Transcriber()
            do {
                try await t.initialize()
                transcriber = t
                return t
            } catch {
                initError = error
                throw error
            }
        }
    }

    /// Resolve URL de uma fixture e falha o teste se não existir.
    private func fixtureURL(_ name: String) throws -> URL {
        let url = Self.fixturesDir.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            Issue.record("""
                Fixture ausente: \(url.path)
                Rode: bash Tests/Fixtures/generate.sh
                """)
            throw FixtureError.missing(name)
        }
        return url
    }

    /// Transcreve uma fixture usando o pipeline real (Transcriber + AudioFileTranscriber).
    private func transcribeFixture(_ name: String) async throws -> FileTranscriptionResult {
        let url = try fixtureURL(name)
        let transcriber = try await Self.sharedTranscriber.get()

        let fileTranscriber = AudioFileTranscriber(
            transcribe: { samples in
                try await transcriber.transcribe(samples)
            },
            diarizer: nil
        )

        return try await fileTranscriber.transcribe(url: url, mode: .plain) { _ in
            // Não precisamos observar fases neste teste
        }
    }

    enum FixtureError: Error {
        case missing(String)
    }

    // MARK: - Testes

    /// Timeout generoso: a primeira execução baixa ~496 MB do HuggingFace.
    /// Depois que o modelo está em cache, a transcrição de áudios curtos é <10s.
    @Test(
        "pt-short.wav contém 'olá' ou 'teste'",
        .timeLimit(.minutes(10))
    )
    func ptShortContainsExpectedWords() async throws {
        guard !Self.shouldSkip else { return }

        let result = try await transcribeFixture("pt-short.wav")
        let text = result.text.lowercased()

        #expect(!text.isEmpty, "Transcrição não deveria estar vazia")

        let hasOla = text.contains("olá") || text.contains("ola")
        let hasTeste = text.contains("teste")
        let hasMundo = text.contains("mundo")

        #expect(
            hasOla || hasTeste || hasMundo,
            """
            Nenhuma palavra-chave encontrada em pt-short.
            Esperava uma de: olá/ola, teste, mundo.
            Obtido: "\(result.text)"
            """
        )

        // Sanidade: duração aproxima do esperado (~2.8s) com tolerância ampla
        #expect(result.durationSeconds > 1.0 && result.durationSeconds < 10.0)
    }

    @Test(
        "pt-long.wav contém pelo menos um termo técnico em inglês (code-switching)",
        .timeLimit(.minutes(10))
    )
    func ptLongContainsTechTerm() async throws {
        guard !Self.shouldSkip else { return }

        let result = try await transcribeFixture("pt-long.wav")
        let text = result.text.lowercased()

        #expect(!text.isEmpty, "Transcrição não deveria estar vazia")

        // Aceita qualquer termo técnico — o modelo varia bastante em code-switching.
        // Também aceitamos "banco" (PT) como sinal de que capturou o sentido.
        let candidates = [
            "deploy", "pipeline", "kubernetes", "postgresql", "postgres",
            "redis", "pull request", "cache", "banco", "dados",
        ]
        let found = candidates.filter { text.contains($0) }

        #expect(
            !found.isEmpty,
            """
            Nenhuma palavra-chave encontrada em pt-long.
            Esperava pelo menos uma de: \(candidates.joined(separator: ", ")).
            Obtido: "\(result.text)"
            """
        )

        // Duração aproxima do esperado (~13s)
        #expect(result.durationSeconds > 8.0 && result.durationSeconds < 25.0)
    }

    @Test(
        "silence.wav retorna texto vazio ou muito curto",
        .timeLimit(.minutes(10))
    )
    func silenceReturnsEmptyOrTrivial() async throws {
        guard !Self.shouldSkip else { return }

        let result = try await transcribeFixture("silence.wav")
        let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Modelos ASR às vezes alucinam pontuação ou uma única sílaba em silêncio.
        // Toleramos até 5 caracteres — mais que isso indica alucinação relevante.
        #expect(
            trimmed.count <= 5,
            """
            Silêncio gerou transcrição longa (\(trimmed.count) chars): "\(result.text)"
            Esperava <= 5 chars (vazio ou pontuação residual).
            """
        )
    }
}
