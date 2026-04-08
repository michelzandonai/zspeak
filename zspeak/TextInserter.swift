import AppKit
import CoreGraphics
import os.log

private let logger = Logger(subsystem: "com.zspeak", category: "TextInserter")

/// Insere texto no app ativo via clipboard + Cmd+V simulado
/// Requer permissão de Acessibilidade (System Settings > Privacy > Accessibility)
struct TextInserter {

    /// App que estava em foco antes de iniciar a gravação
    @MainActor static var previousApp: NSRunningApplication?

    /// Quantidade de chars (grapheme clusters) do último texto colado via insert/replaceLastPaste.
    /// Usado em replaceLastPaste para deletar exatamente N chars via Backspace antes de colar
    /// o novo texto — evita Cmd+Z que agrupa operações e destrói edições anteriores do usuário.
    @MainActor static var lastPastedCount: Int = 0

    /// Salva o app em foco atual (chamar antes de começar gravação)
    @MainActor static func saveFocusedApp() {
        previousApp = NSWorkspace.shared.frontmostApplication
        logger.debug("App em foco salvo: \(previousApp?.localizedName ?? "nenhum")")
    }

    /// Insere texto no app em foco
    /// Retorna true se conseguiu inserir, false se falhou (sem permissão ou erro)
    ///
    /// Não restaura o clipboard anterior — o texto transcrito permanece disponível
    /// para Cmd+V manual caso o paste automático falhe (foco perdido, app lento, etc.).
    /// Ver TASK-010: o restore agressivo apagava a transcrição quando o paste async
    /// falhava silenciosamente, deixando o usuário sem texto em lugar nenhum.
    @discardableResult
    @MainActor func insert(_ text: String) -> Bool {
        // Verifica permissão de Acessibilidade antes de tudo
        guard AXIsProcessTrusted() else {
            logger.error("Sem permissão de Acessibilidade — não é possível simular paste")
            return false
        }

        let pasteboard = NSPasteboard.general

        // Coloca texto transcrito no clipboard (permanece lá para fallback manual)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        Self.lastPastedCount = text.count
        logger.debug("Texto colocado no clipboard (\(text.count) chars)")

        // Reativa o app que estava em foco antes da gravação
        if let app = Self.previousApp {
            guard !app.isTerminated else {
                logger.warning("App anterior (\(app.localizedName ?? "?")) já foi encerrado — texto disponível no clipboard")
                return false
            }
            app.activate()
            logger.debug("App reativado: \(app.localizedName ?? "?")")
        }

        // Delay para o app reativar e clipboard propagar, depois simula Cmd+V
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            let pasteOk = Self.simulatePaste()
            if pasteOk {
                logger.debug("Paste simulado com sucesso")
            } else {
                logger.error("Falha ao simular paste — CGEvent retornou nil. Texto permanece no clipboard.")
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

    /// Substitui o último texto colado enviando Backspace N vezes + novo Cmd+V.
    ///
    /// Por que Backspace e não Cmd+Z: Cmd+Z agrupa operações no undo history de muitos
    /// apps (ex: apps baseados em AppKit, editores web), e desfaz não só o paste original
    /// mas também edições que o usuário fez antes. Backspace N vezes deleta exatamente
    /// os N chars colados previamente sem tocar no histórico de undo. Requer que o cursor
    /// esteja logo após o último paste — caso comum quando o usuário aplica LLM logo
    /// após transcrever.
    @discardableResult
    @MainActor func replaceLastPaste(_ newText: String) -> Bool {
        guard AXIsProcessTrusted() else {
            logger.error("Sem permissão de Acessibilidade — não é possível substituir paste")
            return false
        }

        let charsToDelete = Self.lastPastedCount
        guard charsToDelete > 0 else {
            logger.warning("replaceLastPaste: lastPastedCount = 0, nada para substituir — apenas cola novo texto")
            // Fallback: insere o novo texto normalmente
            return insert(newText)
        }

        let pasteboard = NSPasteboard.general

        // Re-ativa app anterior
        if let app = Self.previousApp {
            guard !app.isTerminated else {
                logger.warning("App anterior (\(app.localizedName ?? "?")) já foi encerrado — texto corrigido será colocado no clipboard")
                pasteboard.clearContents()
                pasteboard.setString(newText, forType: .string)
                Self.lastPastedCount = newText.count
                return false
            }
            app.activate()
            logger.debug("App reativado para replaceLastPaste: \(app.localizedName ?? "?")")
        }

        // Delay para o app reativar
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            // Envia N Backspaces para deletar o texto colado anteriormente
            Self.simulateBackspaces(count: charsToDelete)
            logger.debug("Enviados \(charsToDelete) backspaces para substituir paste anterior")

            // Delay para o app processar os backspaces
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                // Coloca texto corrigido no clipboard (permanece lá — sem restore, ver TASK-010)
                pasteboard.clearContents()
                pasteboard.setString(newText, forType: .string)
                Self.lastPastedCount = newText.count

                // Delay para clipboard propagar
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    let pasteOk = Self.simulatePaste()
                    if !pasteOk {
                        logger.error("replaceLastPaste: simulatePaste falhou. Texto permanece no clipboard.")
                    }
                }
            }
        }

        return true
    }

    /// Envia N eventos de Backspace (keycode 51) em sequência via CGEvent.
    /// Deleta os últimos N chars no campo de texto focado.
    private static func simulateBackspaces(count: Int) {
        guard count > 0 else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        for _ in 0..<count {
            guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: false) else {
                logger.error("simulateBackspaces: CGEvent retornou nil")
                return
            }
            keyDown.post(tap: .cgAnnotatedSessionEventTap)
            keyUp.post(tap: .cgAnnotatedSessionEventTap)
        }
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
