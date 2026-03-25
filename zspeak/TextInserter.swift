import AppKit
import CoreGraphics

/// Insere texto no app ativo via clipboard + Cmd+V simulado
/// Requer permissão de Acessibilidade (System Settings > Privacy > Accessibility)
struct TextInserter {

    /// Insere texto no app em foco
    /// 1. Salva clipboard atual
    /// 2. Coloca texto novo no clipboard
    /// 3. Simula Cmd+V
    /// 4. Restaura clipboard anterior após delay
    func insert(_ text: String) {
        let pasteboard = NSPasteboard.general

        // Salva conteúdo anterior do clipboard
        let previousContents = pasteboard.string(forType: .string)

        // Coloca texto transcrito no clipboard
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Delay para o clipboard propagar
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            // Simula Cmd+V
            Self.simulatePaste()

            // Restaura clipboard anterior após delay
            if let previous = previousContents {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    pasteboard.clearContents()
                    pasteboard.setString(previous, forType: .string)
                }
            }
        }
    }

    /// Simula pressionamento de Cmd+V via CGEvent
    private static func simulatePaste() {
        let source = CGEventSource(stateID: .hidSystemState)

        // V key = keycode 9
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)

        keyDown?.flags = .maskCommand

        keyDown?.post(tap: .cgAnnotatedSessionEventTap)
        keyUp?.post(tap: .cgAnnotatedSessionEventTap)
    }

    /// Verifica se o app tem permissão de Acessibilidade
    static var hasAccessibilityPermission: Bool {
        AXIsProcessTrustedWithOptions(nil)
    }

    /// Solicita permissão de Acessibilidade (abre System Settings)
    static func requestAccessibilityPermission() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}
