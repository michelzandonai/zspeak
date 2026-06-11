import Foundation
import Testing
@testable import zspeak

@Suite("LLMCorrectionManager - Inferencia")
struct LLMCorrectionManagerTests {

    private func makeTmpDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    @Test("Modelo LLM padrao e Qwen3.5 4B OptiQ")
    func testDefaultLLMModelIsQwen35FourB() {
        #expect(LLMCorrectionManager.modelID == "mlx-community/Qwen3.5-4B-OptiQ-4bit")
        #expect(LLMCorrectionManager.modelDisplayName == "Qwen3.5 4B OptiQ")
        #expect(LLMCorrectionManager.modelDetails.contains("4B"))
        #expect(LLMCorrectionManager.modelDetails.contains("OptiQ"))
    }

    @Test("Localizador do MLX encontra metallib junto ao binario")
    func testRuntimeResourceLocatorFindsColocatedMetallib() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let executableURL = tmpDir.appendingPathComponent("zspeak")
        let metallibURL = tmpDir.appendingPathComponent("mlx.metallib")
        try Data([1]).write(to: metallibURL)

        let found = MLXRuntimeResources.firstExistingMetallibURL(
            executableURL: executableURL,
            mainBundleURL: tmpDir,
            bundleResourceURLs: [],
            frameworkResourceURLs: [],
            currentDirectoryURL: tmpDir
        )

        #expect(found?.standardizedFileURL == metallibURL.standardizedFileURL)
    }

    @Test("Localizador do MLX encontra metallib dentro do bundle SwiftPM")
    func testRuntimeResourceLocatorFindsSwiftPMBundleMetallib() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let resourcesURL = tmpDir
            .appendingPathComponent(MLXRuntimeResources.swiftPMBundleName, isDirectory: true)
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resourcesURL, withIntermediateDirectories: true)

        let metallibURL = resourcesURL.appendingPathComponent(MLXRuntimeResources.defaultMetallibName)
        try Data([1]).write(to: metallibURL)

        let found = MLXRuntimeResources.firstExistingMetallibURL(
            executableURL: nil,
            mainBundleURL: tmpDir,
            bundleResourceURLs: [],
            frameworkResourceURLs: [],
            currentDirectoryURL: tmpDir
        )

        #expect(found?.standardizedFileURL == metallibURL.standardizedFileURL)
    }

    @Test("Localizador do MLX encontra metallib direto em resourceURL de bundle")
    func testRuntimeResourceLocatorFindsDirectBundleResourceMetallib() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let metallibURL = tmpDir.appendingPathComponent(MLXRuntimeResources.defaultMetallibName)
        try Data([1]).write(to: metallibURL)

        let found = MLXRuntimeResources.firstExistingMetallibURL(
            executableURL: nil,
            mainBundleURL: tmpDir.appendingPathComponent("App.app", isDirectory: true),
            bundleResourceURLs: [tmpDir],
            frameworkResourceURLs: [],
            currentDirectoryURL: tmpDir.appendingPathComponent("cwd", isDirectory: true)
        )

        #expect(found?.standardizedFileURL == metallibURL.standardizedFileURL)
    }

    @Test("Localizador do MLX ignora metallib vazio")
    func testRuntimeResourceLocatorIgnoresEmptyMetallib() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let executableURL = tmpDir.appendingPathComponent("zspeak")
        let metallibURL = tmpDir.appendingPathComponent("mlx.metallib")
        _ = FileManager.default.createFile(atPath: metallibURL.path, contents: Data())

        let found = MLXRuntimeResources.firstExistingMetallibURL(
            executableURL: executableURL,
            mainBundleURL: tmpDir,
            bundleResourceURLs: [],
            frameworkResourceURLs: [],
            currentDirectoryURL: tmpDir
        )

        #expect(found == nil)
    }

    @Test("Teste prompts variados com texto real longo")
    func testPromptVariados() async throws {
        let manager = LLMCorrectionManager()
        guard await manager.checkModelExists() else {
            print("SKIP: modelo nao baixado")
            return
        }
        guard MLXRuntimeResources.loadableMetallibURL() != nil else {
            print("SKIP: runtime MLX sem metallib valido")
            return
        }
        try await manager.loadModel()
        guard case .ready = await manager.modelState else {
            print("SKIP: modelo nao carregou")
            return
        }

        let texto = "eu preciso configurar o servidor de deploy no kubernetes e tambem ajustar o pipeline de CI CD no github actions porque ta falhando nos testes de integracao e o banco de dados ta com latencia alta"

        // Prompt A: topicos direto
        let promptA = "Reformate o texto abaixo como lista de topicos. Use - no inicio de cada topico. Cada ideia separada deve ser um topico diferente. Nao adicione nada novo. Apenas reorganize:\n\n"

        // Prompt B: correcao pura
        let promptB = "Corrija a ortografia e pontuacao do texto abaixo. Retorne apenas o texto corrigido:"

        // Prompt C: resumo em bullets
        let promptC = "Extraia os pontos principais do texto abaixo em formato de lista com bullets (-):"

        let prompts = [("Topicos", promptA), ("Correcao", promptB), ("Bullets", promptC)]

        for (nome, prompt) in prompts {
            let result = try await manager.correct(text: texto, systemPrompt: prompt, maxTokens: 512)
            print("=== \(nome) ===")
            print(result)
            print("")
        }
    }
}
