import Foundation

/// Contexto em que uma entrada de vocabulário participa do biasing e das
/// substituições. Permite restringir termos a certos tipos de app em foco —
/// ex.: jargão git só quando ditando em terminal/IDE, sem risco de "sequestrar"
/// prosa normal em e-mail ou chat.
enum VocabularyEntryContext: String, Codable, CaseIterable, Sendable {
    /// Participa em qualquer app (default; comportamento histórico).
    case global
    /// Participa apenas quando o app em foco é de desenvolvimento
    /// (terminal, IDE, editor de código — ver `FocusedAppContext`).
    case dev

    var label: String {
        switch self {
        case .global: return "Global"
        case .dev: return "Apps de dev"
        }
    }
}

/// Entrada de vocabulário customizado para context biasing no decoder
struct VocabularyEntry: Identifiable, Codable {
    let id: UUID
    var term: String        // texto correto (ex: "Claude Code")
    var aliases: [String]   // variações/erros comuns (ex: ["cloud code"])
    var weight: Float       // peso de boosting (default 10.0)
    var isEnabled: Bool     // toggle individual
    var context: VocabularyEntryContext  // onde a entrada participa

    init(
        id: UUID = UUID(),
        term: String,
        aliases: [String] = [],
        weight: Float = 10.0,
        isEnabled: Bool = true,
        context: VocabularyEntryContext = .global
    ) {
        self.id = id
        self.term = term
        self.aliases = aliases
        self.weight = weight
        self.isEnabled = isEnabled
        self.context = context
    }

    // Decodificação tolerante: vocabulary.json de instalações antigas não tem
    // a chave `context` — entra como .global (comportamento idêntico ao anterior).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        term = try container.decode(String.self, forKey: .term)
        aliases = try container.decode([String].self, forKey: .aliases)
        weight = try container.decode(Float.self, forKey: .weight)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        // String crua + fallback: um valor desconhecido (versão mais nova do
        // app) degrada para .global em vez de invalidar o JSON inteiro.
        if let raw = try container.decodeIfPresent(String.self, forKey: .context),
           let parsed = VocabularyEntryContext(rawValue: raw) {
            context = parsed
        } else {
            context = .global
        }
    }
}
