import Foundation
import FluidAudio

/// Camada de persistência para vocabulário customizado
@Observable
@MainActor
final class VocabularyStore {
    var entries: [VocabularyEntry] = []

    private let vocabularyFile: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = base.appendingPathComponent("zspeak", isDirectory: true)
        vocabularyFile = appDir.appendingPathComponent("vocabulary.json")
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        entries = loadEntries()
        seedDefaultsIfNeeded(in: appDir)
    }

    /// Inicializador com DI para testes
    init(baseDirectory: URL) {
        vocabularyFile = baseDirectory.appendingPathComponent("vocabulary.json")
        try? FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        entries = loadEntries()
        seedDefaultsIfNeeded(in: baseDirectory)
    }

    // MARK: - API pública

    /// Adiciona uma nova entrada de vocabulário
    func addEntry(term: String, aliases: [String] = [], weight: Float = 10.0) {
        let entry = VocabularyEntry(term: term, aliases: aliases, weight: weight)
        entries.append(entry)
        saveJSON()
    }

    /// Remove uma entrada de vocabulário
    func deleteEntry(_ entry: VocabularyEntry) {
        entries.removeAll { $0.id == entry.id }
        saveJSON()
    }

    /// Constrói contexto de vocabulário para o decoder a partir das entries habilitadas
    func buildVocabularyContext() -> CustomVocabularyContext {
        let terms = entries.filter(\.isEnabled).map { entry in
            CustomVocabularyTerm(
                text: entry.term,
                weight: entry.weight,
                aliases: entry.aliases.isEmpty ? nil : entry.aliases
            )
        }
        return CustomVocabularyContext(terms: terms)
    }

    /// Aplica substituições aliases → term no texto transcrito.
    ///
    /// Fallback em Swift enquanto o context biasing nativo do FluidAudio (`configureVocabularyBoosting`)
    /// estiver indisponível (ver TASK-001 em Transcriber.swift).
    ///
    /// - Busca com word boundaries (`\b`) — não substitui dentro de palavras
    /// - Case-insensitive — "Git Pool", "git pool", "GIT POOL" todos viram o term
    /// - Preserva o casing do term cadastrado pelo usuário
    /// - Aliases mais longos são aplicados primeiro, evitando que um alias curto "vaze"
    ///   dentro de um alias mais longo que ainda não foi processado
    /// - Apenas entradas habilitadas (`isEnabled`) participam
    func applyReplacements(to text: String) -> String {
        guard !text.isEmpty else { return text }

        var pairs: [(alias: String, term: String)] = []
        for entry in entries where entry.isEnabled {
            let term = entry.term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty else { continue }
            for alias in entry.aliases {
                let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                pairs.append((alias: trimmed, term: term))
            }
        }
        pairs.sort { $0.alias.count > $1.alias.count }

        guard !pairs.isEmpty else { return text }

        var result = text
        for (alias, term) in pairs {
            let escapedAlias = NSRegularExpression.escapedPattern(for: alias)
            let pattern = "\\b\(escapedAlias)\\b"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            let range = NSRange(location: 0, length: (result as NSString).length)
            result = regex.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: NSRegularExpression.escapedTemplate(for: term)
            )
        }
        return result
    }

    // MARK: - Persistência JSON

    /// Persiste entries no disco (chamado após edições inline na view)
    func save() {
        saveJSON()
    }

    private func saveJSON() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted

        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: vocabularyFile, options: .atomic)
    }

    private func loadEntries() -> [VocabularyEntry] {
        guard FileManager.default.fileExists(atPath: vocabularyFile.path),
              let data = try? Data(contentsOf: vocabularyFile) else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard let loaded = try? decoder.decode([VocabularyEntry].self, from: data) else {
            return []
        }

        return loaded
    }

    // MARK: - Defaults

    /// Entradas padrão do vocabulário — aplicadas uma única vez por diretório
    /// via flag em disco (`.vocab_defaults_seeded`). Se o usuário deletar uma delas
    /// depois, ela não volta.
    private static let defaultEntries: [(term: String, aliases: [String])] = [
        ("Claude Code", ["cloud code"]),
        ("git pull", ["git pool"])
    ]

    /// Semeia entradas padrão na primeira inicialização (nova instalação ou upgrade).
    /// Idempotente: usa um arquivo flag no mesmo diretório do vocabulary.json para
    /// detectar execuções subsequentes. Não sobrescreve entradas existentes —
    /// apenas adiciona defaults ausentes.
    private func seedDefaultsIfNeeded(in directory: URL) {
        let flagURL = directory.appendingPathComponent(".vocab_defaults_seeded")
        if FileManager.default.fileExists(atPath: flagURL.path) {
            return
        }

        var mutated = false
        for def in Self.defaultEntries {
            let alreadyExists = entries.contains {
                $0.term.caseInsensitiveCompare(def.term) == .orderedSame
            }
            if !alreadyExists {
                entries.append(VocabularyEntry(term: def.term, aliases: def.aliases))
                mutated = true
            }
        }

        if mutated {
            saveJSON()
        }
        try? Data().write(to: flagURL)
    }
}
