import Foundation
import Testing
@testable import zspeak

@Suite("CorrectionPromptStore")
@MainActor
struct CorrectionPromptStoreTests {

    // MARK: - Helpers

    private func makeTmpDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    private func makeStore(in dir: URL) -> CorrectionPromptStore {
        CorrectionPromptStore(baseDirectory: dir)
    }

    // MARK: - Testes

    @Test("Prompts default pré-populados no primeiro uso")
    func testDefaultPromptsPrePopulated() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store = makeStore(in: tmpDir)

        #expect(store.prompts.count == 2)

        let geral = try #require(store.prompts.first { $0.name == "Correção geral" })
        #expect(geral.isActive == true)
        #expect(geral.systemPrompt.contains("ortografia"))

        let formal = try #require(store.prompts.first { $0.name == "Formalizar" })
        #expect(formal.isActive == false)
        #expect(formal.systemPrompt.contains("formal"))
    }

    @Test("activePrompt retorna o prompt ativo")
    func testActivePromptReturnsCorrect() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store = makeStore(in: tmpDir)

        let active = try #require(store.activePrompt)
        #expect(active.name == "Correção geral")
    }

    @Test("addPrompt adiciona e persiste")
    func testAddPromptAddsAndPersists() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store = makeStore(in: tmpDir)
        store.addPrompt(name: "Custom", systemPrompt: "Faça algo custom.")

        #expect(store.prompts.count == 3)
        #expect(store.prompts[2].name == "Custom")
        #expect(store.prompts[2].isActive == false)

        // Persiste no disco
        let store2 = makeStore(in: tmpDir)
        #expect(store2.prompts.count == 3)
        #expect(store2.prompts.contains { $0.name == "Custom" })
    }

    @Test("deletePrompt remove e persiste")
    func testDeletePromptRemovesAndPersists() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store = makeStore(in: tmpDir)
        store.addPrompt(name: "ParaDeletar", systemPrompt: "Temporário.")

        #expect(store.prompts.count == 3)

        let toDelete = try #require(store.prompts.first { $0.name == "ParaDeletar" })
        store.deletePrompt(toDelete)

        #expect(store.prompts.count == 2)
        #expect(store.prompts.contains { $0.name == "ParaDeletar" } == false)

        // Persiste no disco
        let store2 = makeStore(in: tmpDir)
        #expect(store2.prompts.count == 2)
        #expect(store2.prompts.contains { $0.name == "ParaDeletar" } == false)
    }

    @Test("setActive desativa todos exceto o selecionado (radio)")
    func testSetActiveRadioBehavior() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store = makeStore(in: tmpDir)

        // "Correção geral" está ativo por padrão
        #expect(store.activePrompt?.name == "Correção geral")

        // Ativa "Formalizar"
        let formal = try #require(store.prompts.first { $0.name == "Formalizar" })
        store.setActive(formal)

        // Agora só "Formalizar" está ativo
        #expect(store.activePrompt?.name == "Formalizar")

        // Verifica que "Correção geral" foi desativado
        let geral = try #require(store.prompts.first { $0.name == "Correção geral" })
        #expect(geral.isActive == false)

        // Só 1 ativo no total
        let activeCount = store.prompts.filter(\.isActive).count
        #expect(activeCount == 1)
    }

    @Test("Persistência JSON round-trip")
    func testJSONPersistenceRoundTrip() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store1 = makeStore(in: tmpDir)
        store1.addPrompt(name: "Técnico", systemPrompt: "Reescreva com terminologia técnica precisa.")
        store1.addPrompt(name: "Resumo", systemPrompt: "Resuma o texto transcrito em uma frase.")

        // Ativa "Técnico" ao invés do padrão
        let tecnico = try #require(store1.prompts.first { $0.name == "Técnico" })
        store1.setActive(tecnico)

        // Recarrega do disco
        let store2 = makeStore(in: tmpDir)
        // 2 padrão + 2 adicionados
        #expect(store2.prompts.count == 4)

        let tecnicoReloaded = try #require(store2.prompts.first { $0.name == "Técnico" })
        #expect(tecnicoReloaded.isActive == true)
        #expect(tecnicoReloaded.systemPrompt.contains("terminologia"))

        let resumo = try #require(store2.prompts.first { $0.name == "Resumo" })
        #expect(resumo.isActive == false)

        // "Correção geral" deve estar desativado após setActive
        let geral = try #require(store2.prompts.first { $0.name == "Correção geral" })
        #expect(geral.isActive == false)
    }

    @Test("CorrectionPrompt Codable round-trip")
    func testCodableRoundTrip() throws {
        let original = CorrectionPrompt(
            name: "Teste Codable",
            systemPrompt: "Prompt de teste.",
            isActive: true
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(CorrectionPrompt.self, from: data)

        #expect(decoded.id == original.id)
        #expect(decoded.name == original.name)
        #expect(decoded.systemPrompt == original.systemPrompt)
        #expect(decoded.isActive == original.isActive)
    }

    @Test("CorrectionPrompt Equatable por ID")
    func testEquatableByID() throws {
        let id = UUID()
        let a = CorrectionPrompt(id: id, name: "A", systemPrompt: "Prompt A", isActive: true)
        let b = CorrectionPrompt(id: id, name: "B", systemPrompt: "Prompt B", isActive: false)

        // Mesmo ID = mesma identidade (Identifiable)
        #expect(a.id == b.id)
    }
}
