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

    @Test("Modelo LLM padrao vem do catalogo selecionavel")
    func testDefaultLLMModelComesFromSelectableCatalog() {
        let model = LLMModelOption.defaultModel

        #expect(model.id == LLMModelOption.defaultID)
        #expect(model.displayName == "Qwen 3 8B MLX 4-bit")
        #expect(model.subtitle.contains("Padrao seguro"))
        #expect(model.subtitle.contains("~4.35 GB"))
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

@Suite("LLMCorrectionManager - Cache local")
struct LLMCorrectionManagerCacheTests {

    @Test("Estado inicial detecta modelo selecionado ja baixado")
    func initialStateDetectsSelectedModelCache() async throws {
        let fixture = try LLMCacheTestFixture()
        defer { fixture.cleanup() }

        try fixture.cacheModel(id: LLMModelOption.defaultID, byteCount: 128)

        let manager = LLMCorrectionManager(
            userDefaultsSuiteName: fixture.suiteName,
            cacheBaseDirectory: fixture.cacheBaseDirectory
        )

        #expect(await manager.modelState == .downloaded)
        #expect(await manager.checkModelExists())
        #expect(await manager.modelSizeOnDisk() == 128)
    }

    @Test("Estado inicial preserva preset antigo quando ele ja existe no cache")
    func initialStatePreservesCachedRetiredPreset() async throws {
        let fixture = try LLMCacheTestFixture()
        defer { fixture.cleanup() }

        let retiredCachedID = "mlx-community/Qwen3-4B-Instruct-2507-4bit"
        fixture.defaults.set(retiredCachedID, forKey: "selectedLLMModelID")
        try fixture.cacheModel(id: retiredCachedID, byteCount: 256)

        let manager = LLMCorrectionManager(
            userDefaultsSuiteName: fixture.suiteName,
            cacheBaseDirectory: fixture.cacheBaseDirectory
        )

        #expect(await manager.selectedModel.id == retiredCachedID)
        #expect(await manager.modelState == .downloaded)
        #expect(await manager.checkModelExists())
        #expect(await manager.modelSizeOnDisk() == 256)
    }

    @Test("Selecionar modelo usa cache isolado e persiste escolha")
    func selectingModelUsesCacheAndPersistsChoice() async throws {
        let fixture = try LLMCacheTestFixture()
        defer { fixture.cleanup() }

        let modelID = "mlx-community/Phi-4-mini-instruct-4bit"
        try fixture.cacheModel(id: modelID, byteCount: 64)

        let manager = LLMCorrectionManager(
            userDefaultsSuiteName: fixture.suiteName,
            cacheBaseDirectory: fixture.cacheBaseDirectory
        )

        let state = await manager.selectModel(id: modelID)

        #expect(state == .downloaded)
        #expect(await manager.selectedModel.id == modelID)
        #expect(fixture.defaults.string(forKey: "selectedLLMModelID") == modelID)
        #expect(await manager.modelSizeOnDisk() == 64)
    }

    @Test("Lista modelos conhecidos e caches remotos desconhecidos")
    func cachedModelsOnlyListsKnownModels() async throws {
        let fixture = try LLMCacheTestFixture()
        defer { fixture.cleanup() }

        let smallModelID = "mlx-community/Phi-4-mini-instruct-4bit"
        let unknownModelID = "mlx-community/Modelo-Desconhecido-4bit"
        try fixture.cacheModel(id: smallModelID, byteCount: 32)
        try fixture.cacheModel(id: LLMModelOption.defaultID, byteCount: 96)
        try fixture.cacheModel(id: unknownModelID, byteCount: 256)

        let manager = LLMCorrectionManager(
            userDefaultsSuiteName: fixture.suiteName,
            cacheBaseDirectory: fixture.cacheBaseDirectory
        )

        let cachedModels = await manager.cachedModelsOnDisk()
        let ids = cachedModels.map(\.id)

        #expect(ids == [LLMModelOption.defaultID, smallModelID, unknownModelID])
        #expect(cachedModels.first { $0.id == smallModelID }?.sizeBytes == 32)
        #expect(cachedModels.first { $0.id == LLMModelOption.defaultID }?.sizeBytes == 96)
        #expect(cachedModels.first { $0.id == unknownModelID }?.sizeBytes == 256)
    }

    @Test("Remover modelo selecionado limpa cache e volta para nao baixado")
    func deletingSelectedModelRemovesCacheAndState() async throws {
        let fixture = try LLMCacheTestFixture()
        defer { fixture.cleanup() }

        try fixture.cacheModel(id: LLMModelOption.defaultID, byteCount: 128)

        let manager = LLMCorrectionManager(
            userDefaultsSuiteName: fixture.suiteName,
            cacheBaseDirectory: fixture.cacheBaseDirectory
        )

        try await manager.deleteModel()

        #expect(await manager.modelState == .notDownloaded)
        #expect(await manager.modelSizeOnDisk() == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.modelDirectory(for: LLMModelOption.defaultID).path))
    }

    @Test("Cancelar download limpa cache parcial do modelo selecionado")
    func cancelDownloadCleansPartialSelectedModelCache() async throws {
        let fixture = try LLMCacheTestFixture()
        defer { fixture.cleanup() }

        try fixture.cacheModel(id: LLMModelOption.defaultID, byteCount: 128)

        let manager = LLMCorrectionManager(
            userDefaultsSuiteName: fixture.suiteName,
            cacheBaseDirectory: fixture.cacheBaseDirectory
        )

        try await manager.cancelDownloadAndCleanup()

        #expect(await manager.modelState == .notDownloaded)
        #expect(await manager.downloadProgressSnapshot() == nil)
        #expect(await manager.modelSizeOnDisk() == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.modelDirectory(for: LLMModelOption.defaultID).path))
    }

    @Test("Remover outro modelo nao altera estado do modelo selecionado")
    func deletingOtherModelKeepsSelectedModelState() async throws {
        let fixture = try LLMCacheTestFixture()
        defer { fixture.cleanup() }

        let otherModelID = "mlx-community/Phi-4-mini-instruct-4bit"
        try fixture.cacheModel(id: otherModelID, byteCount: 64)

        let manager = LLMCorrectionManager(
            userDefaultsSuiteName: fixture.suiteName,
            cacheBaseDirectory: fixture.cacheBaseDirectory
        )

        try await manager.deleteModel(id: otherModelID)

        #expect(await manager.selectedModel.id == LLMModelOption.defaultID)
        #expect(await manager.modelState == .notDownloaded)
        #expect(!FileManager.default.fileExists(atPath: fixture.modelDirectory(for: otherModelID).path))
    }
}

private struct LLMCacheTestFixture {
    let suiteName: String
    let defaults: UserDefaults
    let rootDirectory: URL
    let cacheBaseDirectory: URL

    init() throws {
        suiteName = "zspeak.tests.llm-cache.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)

        rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zspeak-llm-cache-\(UUID().uuidString)", isDirectory: true)
        cacheBaseDirectory = rootDirectory
            .appendingPathComponent("models", isDirectory: true)

        try FileManager.default.createDirectory(
            at: cacheBaseDirectory,
            withIntermediateDirectories: true
        )
    }

    func cacheModel(id modelID: String, byteCount: Int) throws {
        let directory = modelDirectory(for: modelID)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try Data(repeating: 1, count: byteCount)
            .write(to: directory.appendingPathComponent("weights.safetensors"))
    }

    func modelDirectory(for modelID: String) -> URL {
        cacheBaseDirectory.appendingPathComponent(modelID, isDirectory: true)
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: rootDirectory)
    }
}
