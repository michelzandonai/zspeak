import AppKit
import CoreGraphics
import os.log

private let logger = Logger(subsystem: "com.zspeak", category: "TextInserter")

/// Insere texto no app ativo via clipboard + Cmd+V simulado
/// Requer permissão de Acessibilidade (System Settings > Privacy > Accessibility)
struct TextInserter {

    /// App que estava em foco antes de iniciar a gravação
    @MainActor static var previousApp: NSRunningApplication?

    /// Salva o app em foco atual (chamar antes de começar gravação)
    @MainActor static func saveFocusedApp() {
        previousApp = NSWorkspace.shared.frontmostApplication
        logger.debug("App em foco salvo: \(previousApp?.localizedName ?? "nenhum")")
    }

    /// Insere texto no app em foco
    /// Retorna true se conseguiu inserir, false se falhou (sem permissão ou erro)
    @discardableResult
    @MainActor func insert(_ text: String) -> Bool {
        // Verifica permissão de Acessibilidade antes de tudo
        guard AXIsProcessTrusted() else {
            logger.error("Sem permissão de Acessibilidade — não é possível simular paste")
            return false
        }

        let pasteboard = NSPasteboard.general

        // Salva conteúdo anterior do clipboard
        let previousContents = pasteboard.string(forType: .string)
        logger.debug("Clipboard anterior salvo (\(previousContents?.count ?? 0) chars)")

        // Coloca texto transcrito no clipboard
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        logger.debug("Texto colocado no clipboard (\(text.count) chars)")

        // Reativa o app que estava em foco antes da gravação
        if let app = Self.previousApp {
            guard !app.isTerminated else {
                logger.warning("App anterior (\(app.localizedName ?? "?")) já foi encerrado")
                return false
            }
            app.activate()
            logger.debug("App reativado: \(app.localizedName ?? "?")")
        }

        // Delay para o app reativar e clipboard propagar
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            // Simula Cmd+V
            let pasteOk = Self.simulatePaste()
            if pasteOk {
                logger.debug("Paste simulado com sucesso")
            } else {
                logger.error("Falha ao simular paste — CGEvent retornou nil")
            }

            // Restaura clipboard anterior após delay
            if let previous = previousContents {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    pasteboard.clearContents()
                    pasteboard.setString(previous, forType: .string)
                    logger.debug("Clipboard restaurado")
                }
            }
        }

        return true
    }

    /// Copia texto para o clipboard sem restaurar o conteúdo anterior.
    /// Usado como fallback quando a colagem automática não está disponível.
    @MainActor func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        logger.debug("Texto copiado para o clipboard (\(text.count) chars)")
    }

    /// Simula pressionamento de Cmd+V via CGEvent
    /// Retorna false se CGEvent não pôde ser criado (sem permissão)
    private static func simulatePaste() -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)

        // V key = keycode 9
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            logger.error("CGEvent retornou nil — permissão de Acessibilidade pode estar ausente")
            return false
        }

        keyDown.flags = .maskCommand

        keyDown.post(tap: .cgAnnotatedSessionEventTap)
        keyUp.post(tap: .cgAnnotatedSessionEventTap)
        return true
    }

}
