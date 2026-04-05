import Foundation

/// Entrada de vocabulário customizado para context biasing no decoder
struct VocabularyEntry: Identifiable, Codable {
    let id: UUID
    var term: String        // texto correto (ex: "Claude Code")
    var aliases: [String]   // variações/erros comuns (ex: ["cloud code"])
    var weight: Float       // peso de boosting (default 10.0)
    var isEnabled: Bool     // toggle individual

    init(id: UUID = UUID(), term: String, aliases: [String] = [], weight: Float = 10.0, isEnabled: Bool = true) {
        self.id = id
        self.term = term
        self.aliases = aliases
        self.weight = weight
        self.isEnabled = isEnabled
    }
}
