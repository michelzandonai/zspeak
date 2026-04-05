import Foundation
import Testing
import FluidAudio
@testable import zspeak

@Suite("VocabularyStore")
@MainActor
struct VocabularyStoreTests {

    // MARK: - Helpers

    private func makeTmpDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    private func makeStore(in dir: URL) -> VocabularyStore {
        VocabularyStore(baseDirectory: dir)
    }

    // MARK: - Testes

    @Test("Entrada padrão pré-populada com Claude Code e alias cloud code")
    func testDefaultEntryPrePopulated() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store = makeStore(in: tmpDir)

        #expect(store.entries.count == 1)

        let entry = try #require(store.entries.first)
        #expect(entry.term == "Claude Code")
        #expect(entry.aliases == ["cloud code"])
        #expect(entry.isEnabled == true)
        #expect(entry.weight == 10.0)
    }

    @Test("addEntry adiciona ao final")
    func testAddEntryAppendsToEnd() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store = makeStore(in: tmpDir)
        store.addEntry(term: "Kubernetes", aliases: ["cubernetes"], weight: 8.0)

        // 1 padrão + 1 adicionada
        #expect(store.entries.count == 2)
        #expect(store.entries[0].term == "Claude Code")
        #expect(store.entries[1].term == "Kubernetes")
        #expect(store.entries[1].aliases == ["cubernetes"])
        #expect(store.entries[1].weight == 8.0)
    }

    @Test("addEntry persiste no disco")
    func testAddEntryPersistsToDisk() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store1 = makeStore(in: tmpDir)
        store1.addEntry(term: "SwiftUI")

        // Novo store lendo do mesmo diretório
        let store2 = makeStore(in: tmpDir)
        #expect(store2.entries.count == 2)

        let added = store2.entries.first { $0.term == "SwiftUI" }
        #expect(added != nil)
    }

    @Test("deleteEntry remove entrada")
    func testDeleteEntryRemoves() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store = makeStore(in: tmpDir)
        store.addEntry(term: "Temporário")

        #expect(store.entries.count == 2)

        let toDelete = try #require(store.entries.first { $0.term == "Temporário" })
        store.deleteEntry(toDelete)

        // Só resta a entrada padrão
        #expect(store.entries.count == 1)
        #expect(store.entries[0].term == "Claude Code")
    }

    @Test("deleteEntry persiste no disco")
    func testDeleteEntryPersistsToDisk() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store1 = makeStore(in: tmpDir)
        store1.addEntry(term: "ParaDeletar")

        // Deleta a entrada adicionada
        let toDelete = try #require(store1.entries.first { $0.term == "ParaDeletar" })
        store1.deleteEntry(toDelete)

        // Novo store confirma que foi removida
        let store2 = makeStore(in: tmpDir)
        #expect(store2.entries.count == 1)
        #expect(store2.entries.contains { $0.term == "ParaDeletar" } == false)
    }

    @Test("Persistência JSON round-trip")
    func testJSONPersistenceRoundTrip() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store1 = makeStore(in: tmpDir)
        store1.addEntry(term: "React Native", aliases: ["react nativo"], weight: 5.0)
        store1.addEntry(term: "PostgreSQL", aliases: ["postgres", "postgre"], weight: 12.0)

        // Recarrega do disco
        let store2 = makeStore(in: tmpDir)
        // 1 padrão + 2 adicionadas
        #expect(store2.entries.count == 3)

        let react = try #require(store2.entries.first { $0.term == "React Native" })
        #expect(react.aliases == ["react nativo"])
        #expect(react.weight == 5.0)
        #expect(react.isEnabled == true)

        let pg = try #require(store2.entries.first { $0.term == "PostgreSQL" })
        #expect(pg.aliases == ["postgres", "postgre"])
        #expect(pg.weight == 12.0)
    }

    @Test("buildVocabularyContext inclui apenas habilitadas")
    func testBuildContextOnlyEnabled() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store = makeStore(in: tmpDir)
        store.addEntry(term: "Habilitada")
        store.addEntry(term: "Desabilitada")

        // Desabilita a última entrada
        let idx = try #require(store.entries.firstIndex { $0.term == "Desabilitada" })
        store.entries[idx].isEnabled = false
        store.save()

        let context = store.buildVocabularyContext()
        let terms = context.terms

        // Deve ter "Claude Code" + "Habilitada", mas não "Desabilitada"
        #expect(terms.contains { $0.text == "Claude Code" })
        #expect(terms.contains { $0.text == "Habilitada" })
        #expect(terms.contains { $0.text == "Desabilitada" } == false)
    }

    @Test("buildVocabularyContext inclui aliases")
    func testBuildContextIncludesAliases() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store = makeStore(in: tmpDir)
        store.addEntry(term: "Xcode", aliases: ["x code", "ex code"])

        let context = store.buildVocabularyContext()
        let xcode = try #require(context.terms.first { $0.text == "Xcode" })

        let aliases = try #require(xcode.aliases)
        #expect(aliases.contains("x code"))
        #expect(aliases.contains("ex code"))
    }

    @Test("buildVocabularyContext respeita weight")
    func testBuildContextRespectsWeight() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store = makeStore(in: tmpDir)
        store.addEntry(term: "CustomWeight", weight: 25.0)

        let context = store.buildVocabularyContext()
        let term = try #require(context.terms.first { $0.text == "CustomWeight" })

        #expect(term.weight == 25.0)
    }

    @Test("Entrada desabilitada não aparece no context")
    func testDisabledEntryNotInContext() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store = makeStore(in: tmpDir)

        // Desabilita a entrada padrão
        store.entries[0].isEnabled = false
        store.save()

        let context = store.buildVocabularyContext()
        #expect(context.terms.isEmpty)
    }

    @Test("save() persiste edições inline")
    func testSavePersistsInlineEdits() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store1 = makeStore(in: tmpDir)

        // Edita o termo diretamente (como a view faria)
        store1.entries[0].term = "Claude Code Editado"
        store1.save()

        // Recarrega e verifica
        let store2 = makeStore(in: tmpDir)
        let entry = try #require(store2.entries.first)
        #expect(entry.term == "Claude Code Editado")
    }

    @Test("Store vazio após deletar todas as entradas")
    func testEmptyAfterDeletingAll() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store = makeStore(in: tmpDir)
        #expect(store.entries.count == 1)

        // Deleta a entrada padrão
        let defaultEntry = try #require(store.entries.first)
        store.deleteEntry(defaultEntry)

        #expect(store.entries.isEmpty)

        // Contexto vazio
        let context = store.buildVocabularyContext()
        #expect(context.terms.isEmpty)
    }
}
