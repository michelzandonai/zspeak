import KeyboardShortcuts

/// Define os atalhos de teclado globais do zspeak
extension KeyboardShortcuts.Name {
    /// Atalho para alternar gravação (toggle on/off)
    static let toggleRecording = Self("toggleRecording")
}

/// Gerencia o registro de hotkeys globais
@MainActor
final class HotkeyManager {

    /// Configura o listener da hotkey de toggle
    /// - Parameter onToggle: closure chamada quando a hotkey é pressionada
    func setup(onToggle: @escaping @MainActor () -> Void) {
        KeyboardShortcuts.onKeyDown(for: .toggleRecording) {
            onToggle()
        }
    }
}
