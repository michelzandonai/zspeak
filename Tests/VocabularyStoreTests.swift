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

    @Test("Entradas padrão pré-populadas incluem termos técnicos base")
    func testDefaultEntriesPrePopulated() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store = makeStore(in: tmpDir)

        #expect(store.entries.count > 4)

        let claude = try #require(store.entries.first { $0.term == "Claude Code" })
        #expect(claude.aliases == ["cloud code"])
        #expect(claude.isEnabled == true)
        #expect(claude.weight == 10.0)

        let gitPull = try #require(store.entries.first { $0.term == "git pull" })
        #expect(gitPull.aliases.contains("git pool"))
        #expect(gitPull.aliases.contains("gitpool"))
        #expect(gitPull.aliases.contains("get pull"))
        #expect(gitPull.aliases.contains("get pool"))
        #expect(gitPull.isEnabled == true)

        let branch = try #require(store.entries.first { $0.term == "branch" })
        #expect(branch.aliases.isEmpty)
        #expect(branch.isEnabled == true)
        #expect(branch.weight == 15.0)

        let branches = try #require(store.entries.first { $0.term == "branches" })
        #expect(branches.aliases.isEmpty)
        #expect(branches.isEnabled == true)
        #expect(branches.weight == 15.0)

        let github = try #require(store.entries.first { $0.term == "GitHub" })
        #expect(github.aliases.contains("git hub"))

        let xcodebuild = try #require(store.entries.first { $0.term == "xcodebuild" })
        #expect(xcodebuild.aliases.contains("x code build"))

        let coreML = try #require(store.entries.first { $0.term == "CoreML" })
        #expect(coreML.aliases.contains("core ml"))

        let llm = try #require(store.entries.first { $0.term == "LLM" })
        #expect(llm.aliases.contains("l l m"))

        #expect(store.entries.contains { $0.term == "FluidAudio" })
        #expect(store.entries.contains { $0.term == "Parakeet TDT" })
        #expect(store.entries.contains { $0.term == "Silero VAD" })
        #expect(store.entries.contains { $0.term == "macOS" })

        #expect(store.entries.contains { $0.term == "Codex" })
        #expect(store.entries.contains { $0.term == "git add" })
        #expect(store.entries.contains { $0.term == "fast-forward" })
        #expect(store.entries.contains { $0.term == "XCTest" })
        #expect(store.entries.contains { $0.term == "DMG" })
        #expect(store.entries.contains { $0.term == "ffmpeg" })
        #expect(store.entries.contains { $0.term == "ASR" })
        #expect(store.entries.contains { $0.term == "VAD" })
        #expect(store.entries.contains { $0.term == "Prompt Mode" })
        #expect(store.entries.contains { $0.term == "benchmark" })
        #expect(store.entries.contains { $0.term == "Cmd+V" })
        #expect(store.entries.contains { $0.term == "context biasing" })
        #expect(store.entries.contains { $0.term == "rescoring" })
        #expect(store.entries.contains { $0.term == "RTFx" })
        #expect(store.entries.contains { $0.term == "WER" })
        #expect(store.entries.contains { $0.term == "assertividade" })

        #expect(store.entries.contains { $0.term == "merge request" } == false)
        #expect(store.entries.contains { $0.term == "branch stage" } == false)
    }

    @Test("addEntry adiciona ao final")
    func testAddEntryAppendsToEnd() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store = makeStore(in: tmpDir)
        let defaultCount = store.entries.count
        store.addEntry(term: "Kubernetes", aliases: ["cubernetes"], weight: 8.0)

        #expect(store.entries.count == defaultCount + 1)
        #expect(store.entries.last?.term == "Kubernetes")
        #expect(store.entries.last?.aliases == ["cubernetes"])
        #expect(store.entries.last?.weight == 8.0)
    }

    @Test("addEntry persiste no disco")
    func testAddEntryPersistsToDisk() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store1 = makeStore(in: tmpDir)
        store1.addEntry(term: "SwiftUI")
        let expectedCount = store1.entries.count

        // Novo store lendo do mesmo diretório
        let store2 = makeStore(in: tmpDir)
        #expect(store2.entries.count == expectedCount)

        let added = store2.entries.first { $0.term == "SwiftUI" }
        #expect(added != nil)
    }

    @Test("deleteEntry remove entrada")
    func testDeleteEntryRemoves() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store = makeStore(in: tmpDir)
        let defaultCount = store.entries.count
        store.addEntry(term: "Temporário")

        #expect(store.entries.count == defaultCount + 1)

        let toDelete = try #require(store.entries.first { $0.term == "Temporário" })
        store.deleteEntry(toDelete)

        #expect(store.entries.count == defaultCount)
        #expect(store.entries.contains { $0.term == "Claude Code" })
        #expect(store.entries.contains { $0.term == "git pull" })
        #expect(store.entries.contains { $0.term == "branch" })
        #expect(store.entries.contains { $0.term == "branches" })
    }

    @Test("deleteEntry persiste no disco")
    func testDeleteEntryPersistsToDisk() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store1 = makeStore(in: tmpDir)
        let defaultCount = store1.entries.count
        store1.addEntry(term: "ParaDeletar")

        // Deleta a entrada adicionada
        let toDelete = try #require(store1.entries.first { $0.term == "ParaDeletar" })
        store1.deleteEntry(toDelete)

        // Novo store confirma que foi removida — restam apenas os defaults
        let store2 = makeStore(in: tmpDir)
        #expect(store2.entries.count == defaultCount)
        #expect(store2.entries.contains { $0.term == "ParaDeletar" } == false)
    }

    @Test("Persistência JSON round-trip")
    func testJSONPersistenceRoundTrip() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store1 = makeStore(in: tmpDir)
        let defaultCount = store1.entries.count
        store1.addEntry(term: "React Native", aliases: ["react nativo"], weight: 5.0)
        store1.addEntry(term: "PostgreSQL", aliases: ["postgres", "postgre"], weight: 12.0)

        // Recarrega do disco
        let store2 = makeStore(in: tmpDir)
        #expect(store2.entries.count == defaultCount + 2)

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

        // Deve ter defaults + "Habilitada", mas não "Desabilitada"
        #expect(terms.contains { $0.text == "Claude Code" })
        #expect(terms.contains { $0.text == "git pull" })
        #expect(terms.contains { $0.text == "branch" })
        #expect(terms.contains { $0.text == "branches" })
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

    @Test("buildVocabularyContext usa perfil de assertividade")
    func testBuildContextUsesAccuracyProfile() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store = makeStore(in: tmpDir)
        let context = store.buildVocabularyContext()

        #expect(context.alpha == VocabularyBiasingProfile.alpha)
        #expect(context.minCtcScore == VocabularyBiasingProfile.minCtcScore)
        #expect(context.minSimilarity == VocabularyBiasingProfile.minSimilarity)
        #expect(context.minCombinedConfidence == VocabularyBiasingProfile.minCombinedConfidence)
        #expect(context.minTermLength == VocabularyBiasingProfile.minTermLength)
    }

    @Test("Entrada desabilitada não aparece no context")
    func testDisabledEntryNotInContext() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store = makeStore(in: tmpDir)

        // Desabilita todas as entradas padrão
        for idx in store.entries.indices {
            store.entries[idx].isEnabled = false
        }
        store.save()

        let context = store.buildVocabularyContext()
        #expect(context.terms.isEmpty)
    }

    @Test("save() persiste edições inline")
    func testSavePersistsInlineEdits() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store1 = makeStore(in: tmpDir)

        // Edita o termo Claude Code (como a view faria)
        let idx = try #require(store1.entries.firstIndex { $0.term == "Claude Code" })
        store1.entries[idx].term = "Claude Code Editado"
        store1.save()

        // Recarrega e verifica
        let store2 = makeStore(in: tmpDir)
        #expect(store2.entries.contains { $0.term == "Claude Code Editado" })
        #expect(store2.entries.contains { $0.term == "Claude Code" } == false)
    }

    @Test("Store vazio após deletar todas as entradas")
    func testEmptyAfterDeletingAll() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store = makeStore(in: tmpDir)
        #expect(store.entries.isEmpty == false)

        // Deleta todas as entradas padrão
        while let first = store.entries.first {
            store.deleteEntry(first)
        }

        #expect(store.entries.isEmpty)

        // Contexto vazio
        let context = store.buildVocabularyContext()
        #expect(context.terms.isEmpty)
    }

    @Test("Defaults não voltam após deletar e reinicializar")
    func testDefaultsDoNotResurrectAfterDeletion() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store1 = makeStore(in: tmpDir)
        // Deleta git pull
        let gitPull = try #require(store1.entries.first { $0.term == "git pull" })
        store1.deleteEntry(gitPull)
        #expect(store1.entries.contains { $0.term == "git pull" } == false)

        // Reinicializa do mesmo diretório — flag de seed já existe
        let store2 = makeStore(in: tmpDir)
        #expect(store2.entries.contains { $0.term == "git pull" } == false)
        #expect(store2.entries.contains { $0.term == "Claude Code" })
        #expect(store2.entries.contains { $0.term == "branch" })
        #expect(store2.entries.contains { $0.term == "branches" })
    }

    @Test("Upgrade legado adiciona defaults novos sem ressuscitar batch antigo")
    func testLegacyUpgradeSeedsOnlyNewDefaults() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let legacyEntries = [
            VocabularyEntry(term: "Claude Code", aliases: ["cloud code"]),
            VocabularyEntry(term: "git pull", aliases: ["git pool"])
        ]
        let data = try JSONEncoder().encode(legacyEntries)
        try data.write(to: tmpDir.appendingPathComponent("vocabulary.json"))
        try Data().write(to: tmpDir.appendingPathComponent(".vocab_defaults_seeded"))

        let store = makeStore(in: tmpDir)

        #expect(store.entries.count > 4)
        #expect(store.entries.contains { $0.term == "Claude Code" })
        #expect(store.entries.contains { $0.term == "git pull" })
        #expect(store.entries.contains { $0.term == "branch" })
        #expect(store.entries.contains { $0.term == "branches" })
        #expect(store.entries.contains { $0.term == "GitHub" })
        #expect(store.entries.contains { $0.term == "xcodebuild" })
        #expect(store.entries.contains { $0.term == "LLM" })

        let gitPull = try #require(store.entries.first { $0.term == "git pull" })
        #expect(gitPull.aliases.contains("gitpool"))
        #expect(FileManager.default.fileExists(atPath: tmpDir.appendingPathComponent(".vocab_defaults_seeded_v2").path))
        #expect(FileManager.default.fileExists(atPath: tmpDir.appendingPathComponent(".vocab_defaults_seeded_v3").path))
        #expect(FileManager.default.fileExists(atPath: tmpDir.appendingPathComponent(".vocab_aliases_seeded_v3").path))
        #expect(FileManager.default.fileExists(atPath: tmpDir.appendingPathComponent(".vocab_defaults_seeded_v4").path))
        #expect(FileManager.default.fileExists(atPath: tmpDir.appendingPathComponent(".vocab_defaults_seeded_v5").path))
    }

    @Test("Upgrade adiciona aliases compactos ao git pull sem duplicar termo")
    func testGitPullAliasUpgradeWithoutDuplicateTerm() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let legacyEntries = [
            VocabularyEntry(term: "git pull", aliases: ["git pool"])
        ]
        let data = try JSONEncoder().encode(legacyEntries)
        try data.write(to: tmpDir.appendingPathComponent("vocabulary.json"))
        try Data().write(to: tmpDir.appendingPathComponent(".vocab_defaults_seeded"))
        try Data().write(to: tmpDir.appendingPathComponent(".vocab_defaults_seeded_v2"))
        try Data().write(to: tmpDir.appendingPathComponent(".vocab_defaults_seeded_v3"))

        let store = makeStore(in: tmpDir)

        let gitPullEntries = store.entries.filter { $0.term == "git pull" }
        #expect(gitPullEntries.count == 1)

        let gitPull = try #require(gitPullEntries.first)
        #expect(gitPull.aliases.contains("git pool"))
        #expect(gitPull.aliases.contains("gitpool"))
        #expect(gitPull.aliases.contains("get pull"))
        #expect(gitPull.aliases.contains("get pool"))
        #expect(FileManager.default.fileExists(atPath: tmpDir.appendingPathComponent(".vocab_aliases_seeded_v3").path))
    }

    // MARK: - applyReplacements

    @Test("applyReplacements substitui alias por term — caso básico")
    func testApplyReplacementsBasic() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store = makeStore(in: tmpDir)
        let result = store.applyReplacements(to: "Vou rodar git pool agora")
        #expect(result == "Vou rodar git pull agora")
    }

    @Test("applyReplacements aplica Claude Code default")
    func testApplyReplacementsClaudeCodeDefault() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store = makeStore(in: tmpDir)
        let result = store.applyReplacements(to: "Abri o cloud code no terminal")
        #expect(result == "Abri o Claude Code no terminal")
    }

    @Test("applyReplacements é case-insensitive")
    func testApplyReplacementsCaseInsensitive() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store = makeStore(in: tmpDir)
        #expect(store.applyReplacements(to: "Git Pool é útil") == "git pull é útil")
        #expect(store.applyReplacements(to: "Faz o GitPool na main") == "Faz o git pull na main")
        #expect(store.applyReplacements(to: "Faz o get pool na main") == "Faz o git pull na main")
        #expect(store.applyReplacements(to: "GIT POOL na main") == "git pull na main")
        #expect(store.applyReplacements(to: "Cloud Code é top") == "Claude Code é top")
    }

    @Test("applyReplacements aplica aliases técnicos derivados do uso real")
    func testApplyReplacementsTechnicalAliasesFromUsage() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store = makeStore(in: tmpDir)

        #expect(store.applyReplacements(to: "rodar get add agora") == "rodar git add agora")
        #expect(store.applyReplacements(to: "falhou no fast forward") == "falhou no fast-forward")
        #expect(store.applyReplacements(to: "regravar os branchmarks") == "regravar os benchmarks")
        #expect(store.applyReplacements(to: "abrir o pront mode") == "abrir o Prompt Mode")
        #expect(store.applyReplacements(to: "colar com command v") == "colar com Cmd+V")
        #expect(store.applyReplacements(to: "exportar o d m g") == "exportar o DMG")
        #expect(store.applyReplacements(to: "rodar x c test") == "rodar XCTest")
    }

    @Test("applyReplacements aplica vocabulário cadastrado pelo usuário")
    func testApplyReplacementsUserVocabularyFromHistory() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store = makeStore(in: tmpDir)
        store.addEntry(
            term: "merge request",
            aliases: ["mag request", "médio request"],
            weight: 15.0
        )
        store.addEntry(
            term: "merge requests",
            aliases: ["meg requests"],
            weight: 15.0
        )
        store.addEntry(
            term: "branch stage",
            aliases: ["brent stage", "brand stage", "brain stage", "brand state"],
            weight: 15.0
        )

        #expect(store.applyReplacements(to: "faça um mag request para main") == "faça um merge request para main")
        #expect(store.applyReplacements(to: "faça o médio request para stage") == "faça o merge request para stage")
        #expect(store.applyReplacements(to: "revisar três MEG Requests") == "revisar três merge requests")
        #expect(store.applyReplacements(to: "faça o commit para Brent Stage") == "faça o commit para branch stage")
        #expect(store.applyReplacements(to: "crie uma brand stage com base na main") == "crie uma branch stage com base na main")
        #expect(store.applyReplacements(to: "ajuste essa parte na Brain Stage") == "ajuste essa parte na branch stage")
        #expect(store.applyReplacements(to: "faz o commit para Brand State") == "faz o commit para branch stage")
    }

    @Test("applyReplacements preserva casing do term cadastrado")
    func testApplyReplacementsPreservesTermCasing() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store = makeStore(in: tmpDir)
        // O term é "Claude Code" (C e C maiúsculos) — qualquer variação do alias
        // deve virar exatamente "Claude Code"
        #expect(store.applyReplacements(to: "CLOUD CODE") == "Claude Code")
        #expect(store.applyReplacements(to: "cloud code") == "Claude Code")
    }

    @Test("applyReplacements respeita word boundaries")
    func testApplyReplacementsWordBoundary() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store = makeStore(in: tmpDir)
        store.addEntry(term: "push", aliases: ["posh"])

        // "posh" dentro de outra palavra não deve ser substituído
        #expect(store.applyReplacements(to: "poshness é uma palavra") == "poshness é uma palavra")

        // "posh" como palavra isolada deve ser substituído
        #expect(store.applyReplacements(to: "vou posh agora") == "vou push agora")

        // Pontuação adjacente conta como word boundary
        #expect(store.applyReplacements(to: "posh, commit, push") == "push, commit, push")
    }

    @Test("applyReplacements não altera texto sem matches")
    func testApplyReplacementsNoMatch() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store = makeStore(in: tmpDir)
        let input = "Texto sem nenhuma substituição relevante"
        #expect(store.applyReplacements(to: input) == input)
    }

    @Test("applyReplacements retorna string vazia para input vazio")
    func testApplyReplacementsEmptyInput() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store = makeStore(in: tmpDir)
        #expect(store.applyReplacements(to: "") == "")
    }

    @Test("applyReplacements ignora entradas desabilitadas")
    func testApplyReplacementsIgnoresDisabled() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store = makeStore(in: tmpDir)
        // Desabilita git pull
        let idx = try #require(store.entries.firstIndex { $0.term == "git pull" })
        store.entries[idx].isEnabled = false
        store.save()

        // Git pool não deve ser substituído
        #expect(store.applyReplacements(to: "rodar git pool") == "rodar git pool")
        // Mas Claude Code (habilitado) continua funcionando
        #expect(store.applyReplacements(to: "abrir cloud code") == "abrir Claude Code")
    }

    @Test("applyReplacements suporta múltiplos aliases na mesma entrada")
    func testApplyReplacementsMultipleAliases() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store = makeStore(in: tmpDir)
        store.addEntry(term: "PostgreSQL", aliases: ["postgres", "postgre", "post gree"])

        #expect(store.applyReplacements(to: "instalar postgres") == "instalar PostgreSQL")
        #expect(store.applyReplacements(to: "instalar postgre") == "instalar PostgreSQL")
        #expect(store.applyReplacements(to: "instalar post gree") == "instalar PostgreSQL")
    }

    @Test("applyReplacements aplica várias substituições no mesmo texto")
    func testApplyReplacementsMultipleInSameText() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store = makeStore(in: tmpDir)
        let result = store.applyReplacements(to: "abrir cloud code e rodar git pool")
        #expect(result == "abrir Claude Code e rodar git pull")
    }

    @Test("applyReplacements ordena aliases por comprimento decrescente")
    func testApplyReplacementsLongestAliasFirst() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store = makeStore(in: tmpDir)
        // Dois termos: um com alias curto, outro com alias longo que contém o curto
        store.addEntry(term: "alpha-beta", aliases: ["foo bar"])
        store.addEntry(term: "baz", aliases: ["foo"])

        // "foo bar" deve virar "alpha-beta" — não pode ser fragmentado em
        // "foo" (virando "baz") + " bar"
        let result = store.applyReplacements(to: "abrir foo bar agora")
        #expect(result == "abrir alpha-beta agora")
    }

    @Test("applyReplacements ignora aliases vazios/whitespace")
    func testApplyReplacementsIgnoresEmptyAliases() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store = makeStore(in: tmpDir)
        store.addEntry(term: "Xcode", aliases: ["", "  ", "x code"])

        // Aliases vazios não devem causar crash nem substituir nada inesperado
        let result = store.applyReplacements(to: "abrir x code agora")
        #expect(result == "abrir Xcode agora")
    }

    @Test("applyReplacements escapa caracteres especiais de regex no alias")
    func testApplyReplacementsEscapesRegexSpecials() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store = makeStore(in: tmpDir)
        // Alias com caractere especial de regex (ponto) — não deve ser interpretado
        // como "qualquer caractere". Aqui o term termina com letra, então word boundary funciona.
        store.addEntry(term: "Node", aliases: ["nodejs"])

        // "nodejs" deve virar "Node"
        #expect(store.applyReplacements(to: "instalar nodejs") == "instalar Node")
        // "nodejs" dentro de outra palavra não deve ser substituído
        #expect(store.applyReplacements(to: "nodejsx") == "nodejsx")
    }

    // Regressão: o pattern antigo usava `\b`, que exige transição word/non-word.
    // Alias começando ou terminando em símbolo (".net", "c++") nunca casava —
    // `\b` entre espaço e "." não existe. O lookaround corrige isso.
    @Test("applyReplacements casa alias com símbolo nas bordas")
    func testApplyReplacementsAliasWithEdgeSymbols() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store = makeStore(in: tmpDir)
        store.addEntry(term: ".NET", aliases: [".net"])
        store.addEntry(term: "C++", aliases: ["c++"])

        #expect(store.applyReplacements(to: "programar em .net agora") == "programar em .NET agora")
        #expect(store.applyReplacements(to: "usar c++ no projeto") == "usar C++ no projeto")
        // Bordas com letra/número continuam bloqueando o match
        #expect(store.applyReplacements(to: "usar c++x no projeto") == "usar c++x no projeto")
    }

    // Regressão: o cache de regex compilados precisa ser invalidado em toda
    // mutação de entries — senão um alias novo só funcionava após reiniciar.
    @Test("Cache de replacements é invalidado após addEntry e deleteEntry")
    func testReplacementCacheInvalidatedOnMutation() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store = makeStore(in: tmpDir)
        // Primeira chamada compila e cacheia as regras
        _ = store.applyReplacements(to: "aquecer o cache")

        // Termo inexistente nos seeds — evita colidir com defaults como "Docker"
        store.addEntry(term: "Terraform", aliases: ["terra forme"])
        #expect(store.applyReplacements(to: "rodar terra forme agora") == "rodar Terraform agora")

        let added = try #require(store.entries.first { $0.term == "Terraform" })
        store.deleteEntry(added)
        #expect(store.applyReplacements(to: "rodar terra forme agora") == "rodar terra forme agora")
    }

    // Regressão: os seeds antigos tinham aliases perigosos — "wave" (palavra
    // real em inglês) virava "WAV", "head"/"opus" idem. Só "uav" (erro fonético
    // real do ASR) deve permanecer como alias de WAV.
    @Test("Seeds não sequestram palavras comuns: wave/head/opus intactos")
    func testSeedsDoNotHijackCommonWords() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store = makeStore(in: tmpDir)

        let wav = try #require(store.entries.first { $0.term == "WAV" })
        #expect(wav.aliases == ["uav"])
        let head = try #require(store.entries.first { $0.term == "HEAD" })
        #expect(head.aliases.isEmpty)
        let opus = try #require(store.entries.first { $0.term == "OPUS" })
        #expect(opus.aliases.isEmpty)

        // Palavras comuns não são reescritas
        #expect(store.applyReplacements(to: "a sound wave passed") == "a sound wave passed")
        #expect(store.applyReplacements(to: "the head of the file") == "the head of the file")
        #expect(store.applyReplacements(to: "modelo opus da anthropic") == "modelo opus da anthropic")

        // O erro fonético real continua corrigido
        #expect(store.applyReplacements(to: "exportar como uav") == "exportar como WAV")
    }

    // Regressão: instalações existentes tinham "wave"/"head"/"opus" persistidos
    // no vocabulary.json — corrigir só os seeds novos não as alcançava.
    @Test("Migração v6 remove aliases perigosos de instalação existente")
    func testV6MigrationStripsDangerousAliasesFromExistingInstall() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Simula vocabulary.json de instalação antiga, com todos os flags de
        // seed já gravados (só a migração v6 deve rodar)
        let legacyEntries = [
            VocabularyEntry(term: "WAV", aliases: ["uav", "wave"], weight: 8.0),
            VocabularyEntry(term: "HEAD", aliases: ["head"], weight: 8.0),
            VocabularyEntry(term: "OPUS", aliases: ["opus"], weight: 8.0),
            VocabularyEntry(term: "git pull", aliases: ["git pool"], weight: 10.0)
        ]
        let data = try JSONEncoder().encode(legacyEntries)
        try data.write(to: tmpDir.appendingPathComponent("vocabulary.json"))
        for flag in [".vocab_defaults_seeded", ".vocab_defaults_seeded_v2", ".vocab_defaults_seeded_v3",
                     ".vocab_aliases_seeded_v3", ".vocab_defaults_seeded_v4", ".vocab_defaults_seeded_v5"] {
            try Data().write(to: tmpDir.appendingPathComponent(flag))
        }

        let store = makeStore(in: tmpDir)

        let wav = try #require(store.entries.first { $0.term == "WAV" })
        #expect(wav.aliases == ["uav"])
        let head = try #require(store.entries.first { $0.term == "HEAD" })
        #expect(head.aliases.isEmpty)
        let opus = try #require(store.entries.first { $0.term == "OPUS" })
        #expect(opus.aliases.isEmpty)

        // Aliases legítimos de outras entradas ficam intactos
        let gitPull = try #require(store.entries.first { $0.term == "git pull" })
        #expect(gitPull.aliases.contains("git pool"))

        // Palavras comuns deixam de ser reescritas imediatamente
        #expect(store.applyReplacements(to: "a sound wave passed") == "a sound wave passed")

        // Flag gravado: migração não roda de novo (usuário pode re-adicionar o alias)
        #expect(FileManager.default.fileExists(atPath: tmpDir.appendingPathComponent(".vocab_alias_cleanup_v6").path))
        let store2 = makeStore(in: tmpDir)
        store2.addEntry(term: "Wave", aliases: [])
        #expect(store2.entries.contains { $0.term == "Wave" })
    }

    // MARK: - Contexto por app (perfis dev/global)

    @Test("Entrada legada sem chave context decodifica como .global")
    func testLegacyEntryDecodesAsGlobal() throws {
        let json = """
        {"id":"\(UUID().uuidString)","term":"git pull","aliases":["git pool"],"weight":10,"isEnabled":true}
        """
        let entry = try JSONDecoder().decode(VocabularyEntry.self, from: Data(json.utf8))
        #expect(entry.context == .global)
    }

    @Test("Valor de context desconhecido degrada para .global em vez de falhar")
    func testUnknownContextDecodesAsGlobal() throws {
        let json = """
        {"id":"\(UUID().uuidString)","term":"x","aliases":[],"weight":10,"isEnabled":true,"context":"futuro"}
        """
        let entry = try JSONDecoder().decode(VocabularyEntry.self, from: Data(json.utf8))
        #expect(entry.context == .global)
    }

    @Test("Context .dev sobrevive a roundtrip de persistência")
    func testDevContextRoundtrip() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store = makeStore(in: tmpDir)
        store.addEntry(term: "kubectl", aliases: ["cube control"], weight: 12, context: .dev)

        let reloaded = makeStore(in: tmpDir)
        let entry = try #require(reloaded.entries.first { $0.term == "kubectl" })
        #expect(entry.context == .dev)
    }

    @Test("buildVocabularyContext filtra entradas .dev fora de apps de dev")
    func testBuildContextFiltersByCategory() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store = makeStore(in: tmpDir)
        store.addEntry(term: "Terraform", aliases: ["terra forme"], context: .global)
        store.addEntry(term: "kubectl", aliases: ["cube control"], context: .dev)

        let globalOnly = store.buildVocabularyContext(categories: [.global])
        #expect(globalOnly.terms.contains { $0.text == "Terraform" })
        #expect(!globalOnly.terms.contains { $0.text == "kubectl" })

        let devToo = store.buildVocabularyContext(categories: [.global, .dev])
        #expect(devToo.terms.contains { $0.text == "kubectl" })

        // Default (sem argumento) mantém o comportamento histórico: tudo entra
        let all = store.buildVocabularyContext()
        #expect(all.terms.contains { $0.text == "kubectl" })
    }

    @Test("applyReplacements respeita as categorias ativas e o cache por categoria")
    func testApplyReplacementsByCategory() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store = makeStore(in: tmpDir)
        store.addEntry(term: "kubectl", aliases: ["cube control"], context: .dev)

        // Fora de app dev: alias .dev não dispara (e o cache global-only compila)
        #expect(store.applyReplacements(to: "roda cube control ai", categories: [.global])
            == "roda cube control ai")
        // Em app dev: dispara (cache é por conjunto de categorias, não pode vazar)
        #expect(store.applyReplacements(to: "roda cube control ai", categories: [.global, .dev])
            == "roda kubectl ai")

        // Mutação invalida os DOIS caches
        store.addEntry(term: "Terraform", aliases: ["terra forme"], context: .global)
        #expect(store.applyReplacements(to: "sobe terra forme", categories: [.global])
            == "sobe Terraform")
        #expect(store.applyReplacements(to: "sobe terra forme e cube control", categories: [.global, .dev])
            == "sobe Terraform e kubectl")
    }

    @Test("FocusedAppContext classifica terminais e IDEs como dev")
    func testFocusedAppContextClassification() {
        // Sem bundle (desconhecido) → só global
        #expect(FocusedAppContext.categories(forBundleID: nil) == [.global])
        // Apps comuns → só global
        #expect(FocusedAppContext.categories(forBundleID: "com.apple.Safari") == [.global])
        #expect(FocusedAppContext.categories(forBundleID: "com.apple.mail") == [.global])
        // Terminais e IDEs → dev
        #expect(FocusedAppContext.categories(forBundleID: "com.apple.Terminal").contains(.dev))
        #expect(FocusedAppContext.categories(forBundleID: "com.googlecode.iterm2").contains(.dev))
        #expect(FocusedAppContext.categories(forBundleID: "com.microsoft.VSCode").contains(.dev))
        #expect(FocusedAppContext.categories(forBundleID: "com.apple.dt.Xcode").contains(.dev))
        // Prefixo cobre a família JetBrains inteira
        #expect(FocusedAppContext.categories(forBundleID: "com.jetbrains.WebStorm").contains(.dev))
        // Prefixo não pode casar substring no meio do bundle
        #expect(FocusedAppContext.categories(forBundleID: "br.com.jetbrains.fake") == [.global])
    }

    // MARK: - Fluxo do modal de novo termo

    @Test("addEntry com prepend insere no topo da lista")
    func testAddEntryPrepend() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let store = makeStore(in: tmpDir)

        store.addEntry(term: "no fim", aliases: [], weight: 5)
        store.addEntry(term: "no topo", aliases: ["alias"], weight: 12, context: .dev, prepend: true)

        #expect(store.entries.first?.term == "no topo")
        #expect(store.entries.first?.context == .dev)
        #expect(store.entries.last?.term == "no fim")
    }

    @Test("removeEmptyEntries apaga só entradas totalmente em branco")
    func testRemoveEmptyEntries() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let store = makeStore(in: tmpDir)
        let seedCount = store.entries.count

        // Artefatos do fluxo antigo: termo vazio, sem alias útil
        store.addEntry(term: "", aliases: [], weight: 10)
        store.addEntry(term: "   ", aliases: ["", "  "], weight: 10)
        // Entrada incompleta mas com alias digitado — deve SOBREVIVER
        store.addEntry(term: "", aliases: ["cuber netes"], weight: 10)

        let removed = store.removeEmptyEntries()

        #expect(removed == 2)
        #expect(store.entries.count == seedCount + 1)
        #expect(store.entries.contains { $0.aliases == ["cuber netes"] })

        // Persistiu: reabrir o store não ressuscita as entradas em branco
        let reloaded = makeStore(in: tmpDir)
        #expect(reloaded.entries.count == seedCount + 1)

        // Idempotente: segunda passada não remove nada
        #expect(store.removeEmptyEntries() == 0)
    }

    @Test("parseAliasesInput separa por vírgula e quebra de linha, aparando vazios")
    func testParseAliasesInput() {
        #expect(VocabularyStore.parseAliasesInput("cloud code, claud code") == ["cloud code", "claud code"])
        #expect(VocabularyStore.parseAliasesInput("um\ndois , três ") == ["um", "dois", "três"])
        #expect(VocabularyStore.parseAliasesInput("  ,, \n ,") == [])
        #expect(VocabularyStore.parseAliasesInput("") == [])
        #expect(VocabularyStore.parseAliasesInput("único") == ["único"])
    }
}
