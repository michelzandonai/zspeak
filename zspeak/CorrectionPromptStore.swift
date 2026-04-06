import Foundation

/// Camada de persistência para prompts de correção LLM
@Observable
@MainActor
final class CorrectionPromptStore {
    var prompts: [CorrectionPrompt] = []

    private let promptsFile: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = base.appendingPathComponent("zspeak", isDirectory: true)
        promptsFile = appDir.appendingPathComponent("correction-prompts.json")
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

    private func saveJSON() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted

        guard let data = try? encoder.encode(prompts) else { return }
        try? data.write(to: promptsFile, options: .atomic)
    }

    private func loadPrompts() -> [CorrectionPrompt] {
        guard FileManager.default.fileExists(atPath: promptsFile.path),
              let data = try? Data(contentsOf: promptsFile) else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard let loaded = try? decoder.decode([CorrectionPrompt].self, from: data) else {
            return []
        }

        return loaded
    }
}
