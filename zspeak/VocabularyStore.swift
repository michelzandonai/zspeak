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

        // Pré-popular com termo padrão no primeiro uso
        if entries.isEmpty {
            entries.append(VocabularyEntry(term: "Claude Code", aliases: ["cloud code"]))
            saveJSON()
        }
    }

    /// Inicializador com DI para testes
    init(baseDirectory: URL) {
        vocabularyFile = baseDirectory.appendingPathComponent("vocabulary.json")
        try? FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        entries = loadEntries()

        if entries.isEmpty {
            entries.append(VocabularyEntry(term: "Claude Code", aliases: ["cloud code"]))
            saveJSON()
        }
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
}
