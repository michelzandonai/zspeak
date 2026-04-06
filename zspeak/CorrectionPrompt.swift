import Foundation

/// Prompt de correção LLM para pós-processamento de transcrições
struct CorrectionPrompt: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String           // nome descritivo (ex: "Correção geral")
    var systemPrompt: String   // instrução sistema pro LLM
    var isActive: Bool         // só 1 ativo por vez (radio)

    init(id: UUID = UUID(), name: String, systemPrompt: String, isActive: Bool = false) {
        self.id = id
        self.name = name
        self.systemPrompt = systemPrompt
        self.isActive = isActive
    }
}
