import Foundation

/// Camada de persistência para prompts de correção LLM
@Observable
@MainActor
final class CorrectionPromptStore {
    var prompts: [CorrectionPrompt] = []

    private let promptsFile: URL

    /// Fila serial dedicada a encode + I/O. Fora da main thread.
    @ObservationIgnored
    private let persistQueue: DispatchQueue

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = base.appendingPathComponent("zspeak", isDirectory: true)
        promptsFile = appDir.appendingPathComponent("correction-prompts.json")
        persistQueue = StorePersistQueue.shared(forFileAt: promptsFile)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        prompts = loadPrompts()

        // Pré-popular com prompts padrão no primeiro uso
        if prompts.isEmpty {
            prompts.append(CorrectionPrompt(
                name: "Correção geral",
                systemPrompt: "Corrija ortografia, pontuação e capitalização do texto transcrito. Mantenha o significado original e termos técnicos em inglês. Retorne apenas o texto corrigido, sem explicações.",
                isActive: true
            ))
            prompts.append(CorrectionPrompt(
                name: "Formalizar",
                systemPrompt: "Reescreva o texto transcrito em tom mais formal e profissional. Mantenha termos técnicos em inglês. Retorne apenas o texto reescrito, sem explicações.",
                isActive: false
            ))
            saveJSON()
        }
    }

    /// Inicializador com DI para testes
    init(baseDirectory: URL) {
        promptsFile = baseDirectory.appendingPathComponent("correction-prompts.json")
        persistQueue = StorePersistQueue.shared(forFileAt: promptsFile)
        try? FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        prompts = loadPrompts()

        if prompts.isEmpty {
            prompts.append(CorrectionPrompt(
                name: "Correção geral",
                systemPrompt: "Corrija ortografia, pontuação e capitalização do texto transcrito. Mantenha o significado original e termos técnicos em inglês. Retorne apenas o texto corrigido, sem explicações.",
                isActive: true
            ))
            prompts.append(CorrectionPrompt(
                name: "Formalizar",
                systemPrompt: "Reescreva o texto transcrito em tom mais formal e profissional. Mantenha termos técnicos em inglês. Retorne apenas o texto reescrito, sem explicações.",
                isActive: false
            ))
            saveJSON()
        }
    }

    // MARK: - API pública

    /// Adiciona um novo prompt de correção
    func addPrompt(name: String, systemPrompt: String) {
        let prompt = CorrectionPrompt(name: name, systemPrompt: systemPrompt)
        prompts.append(prompt)
        saveJSON()
    }

    /// Remove um prompt de correção
    func deletePrompt(_ prompt: CorrectionPrompt) {
        prompts.removeAll { $0.id == prompt.id }
        saveJSON()
    }

    /// Define o prompt ativo (radio behavior: desativa todos, ativa só esse)
    func setActive(_ prompt: CorrectionPrompt) {
        for i in prompts.indices {
            prompts[i].isActive = (prompts[i].id == prompt.id)
        }
        saveJSON()
    }

    /// Prompt atualmente ativo (computed)
    var activePrompt: CorrectionPrompt? {
        prompts.first { $0.isActive }
    }

    /// Persiste prompts no disco (chamado após edições inline na view)
    func save() {
        saveJSON()
    }

    // MARK: - Persistência JSON

    /// Envelope versionado: `{ schemaVersion: 1, prompts: [...] }`.
    fileprivate struct Envelope: Codable {
        let schemaVersion: Int
        let prompts: [CorrectionPrompt]
    }

    /// Captura snapshot no main e enfileira encode+write no background.
    private func saveJSON() {
        let snapshot = prompts
        let file = promptsFile
        persistQueue.async {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

            let envelope = Envelope(
                schemaVersion: CorrectionPromptStoreSchema.currentVersion,
                prompts: snapshot
            )

            guard let data = try? encoder.encode(envelope) else { return }
            try? data.write(to: file, options: .atomic)
        }
    }

    private func loadPrompts() -> [CorrectionPrompt] {
        // Drena writes pendentes antes de reler.
        persistQueue.sync { }

        guard FileManager.default.fileExists(atPath: promptsFile.path) else {
            return []
        }

        let data: Data
        do {
            data = try Data(contentsOf: promptsFile)
        } catch {
            StoreLog.shared.log("CorrectionPromptStore: falha ao ler \(promptsFile.lastPathComponent): \(error)")
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if let envelope = try? decoder.decode(Envelope.self, from: data) {
            if envelope.schemaVersion == CorrectionPromptStoreSchema.currentVersion {
                return envelope.prompts
            }
            StoreLog.shared.log("CorrectionPromptStore: schemaVersion desconhecida \(envelope.schemaVersion); fazendo backup e começando vazio")
            StoreLog.shared.backup(fileURL: promptsFile)
            return []
        }

        if let legacy = try? decoder.decode([CorrectionPrompt].self, from: data) {
            return legacy
        }

        StoreLog.shared.log("CorrectionPromptStore: JSON malformado em \(promptsFile.lastPathComponent); fazendo backup")
        StoreLog.shared.backup(fileURL: promptsFile)
        return []
    }
}

// MARK: - Constants / schema

/// Versão corrente do schema persistido de `CorrectionPromptStore`.
enum CorrectionPromptStoreSchema {
    static let currentVersion = 1
}
