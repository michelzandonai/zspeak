import Foundation

/// Modo Prompt LLM toggleável — quando ativo, mantém o overlay visível
/// com lista de prompts clicáveis para correção da última transcrição.
@Observable
@MainActor
final class PromptModeManager {
    var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: "promptModeEnabled") }
    }

    init() {
        self.isEnabled = UserDefaults.standard.bool(forKey: "promptModeEnabled")
    }

    func toggle() {
        isEnabled.toggle()
    }

    func disable() {
        isEnabled = false
    }

    func enable() {
        isEnabled = true
    }
}
