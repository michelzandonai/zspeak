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

    /// Task pendente de restauração do clipboard, agendada após paste bem-sucedido.
    /// Operações subsequentes aguardam sua conclusão antes de capturar novo snapshot,
    /// para não fotografar um estado intermediário nosso em vez do conteúdo do usuário.
    @MainActor static var pendingClipboardRestore: Task<Void, Never>?

    /// Delay antes de restaurar o clipboard após o Cmd+V — o app alvo lê o
    /// pasteboard de forma assíncrona ao processar o evento de teclado.
    @MainActor static var clipboardRestoreDelay: UInt64 = 300_000_000

    /// Salva o app em foco atual (chamar antes de começar gravação)
    @MainActor static func saveFocusedApp() {
        previousApp = NSWorkspace.shared.frontmostApplication
        logger.debug("App em foco salvo: \(previousApp?.localizedName ?? "nenhum")")
    }

    /// Aguarda a conclusão da restauração pendente (se houver) antes de uma nova
    /// operação de paste — sem isso, o snapshot seguinte fotografaria nossa própria
    /// transcrição em vez do conteúdo original do usuário.
    @MainActor static func awaitPendingClipboardRestore() async {
        if let pending = pendingClipboardRestore {
            await pending.value
            pendingClipboardRestore = nil
        }
    }

    /// Agenda a devolução do snapshot ao clipboard após `clipboardRestoreDelay`.
    /// A restauração só acontece se o `changeCount` não mudou nesse meio tempo —
    /// se o usuário ou outro app copiou algo novo, o conteúdo mais recente vence.
    /// Snapshot vazio não agenda nada: não há o que devolver e a transcrição
    /// permanece no clipboard.
    @MainActor static func scheduleClipboardRestore(
        _ snapshot: ClipboardSnapshot,
        to pasteboard: NSPasteboard,
        ifChangeCountIs expected: Int
    ) {
        guard !snapshot.isEmpty else { return }
        pendingClipboardRestore = Task { @MainActor in
            try? await Task.sleep(nanoseconds: clipboardRestoreDelay)
            guard !Task.isCancelled else { return }
            if snapshot.restore(to: pasteboard, ifChangeCountIs: expected) {
                logger.debug("Clipboard anterior do usuário restaurado após paste")
            } else {
                logger.debug("Restore do clipboard pulado — conteúdo mudou após o paste")
            }
        }
    }

    /// Insere texto no app em foco
    /// Retorna true se conseguiu inserir, false se falhou (sem permissão ou erro)
    ///
    /// Restaura o clipboard anterior do usuário SOMENTE após paste bem-sucedido,
    /// com delay e condicional ao changeCount. Em falha de paste, a transcrição
    /// permanece no clipboard para Cmd+V manual — ver TASK-010: o restore
    /// incondicional apagava a transcrição quando o paste async falhava
    /// silenciosamente, deixando o usuário sem texto em lugar nenhum.
    @discardableResult
    @MainActor func insert(_ text: String) async -> Bool {
        // Verifica permissão de Acessibilidade antes de tudo
        guard AXIsProcessTrusted() else {
            logger.error("Sem permissão de Acessibilidade — não é possível simular paste")
            Self.lastPastedCount = 0
            return false
        }

        // Aguarda restauração pendente de um paste anterior para fotografar o
        // conteúdo real do usuário, não um estado intermediário nosso.
        await Self.awaitPendingClipboardRestore()

        let pasteboard = NSPasteboard.general

        // Fotografa o conteúdo do usuário antes de sobrescrever, para devolver após o paste
        let snapshot = ClipboardSnapshot.capture(from: pasteboard)

        // Coloca texto transcrito no clipboard (permanece lá para fallback manual)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let transcriptChangeCount = pasteboard.changeCount
        logger.debug("Texto colocado no clipboard (\(text.count) chars)")

        // Reativa o app que estava em foco antes da gravação
        if let app = Self.previousApp {
            guard !app.isTerminated else {
                logger.warning("App anterior (\(app.localizedName ?? "?")) já foi encerrado — texto disponível no clipboard")
                Self.lastPastedCount = 0
                return false
            }
            app.activate()
            logger.debug("App reativado: \(app.localizedName ?? "?")")
        }

        // Delay para o app reativar e clipboard propagar, depois simula Cmd+V
        try? await Task.sleep(nanoseconds: 250_000_000)
        let pasteOk = Self.simulatePaste()
        if pasteOk {
            logger.debug("Paste simulado com sucesso")
            // Devolve o conteúdo anterior do usuário depois que o app alvo
            // consumir o Cmd+V. Em falha, nada é agendado: a transcrição fica
            // no clipboard como fallback manual (TASK-010).
            Self.scheduleClipboardRestore(snapshot, to: pasteboard, ifChangeCountIs: transcriptChangeCount)
        } else {
            logger.error("Falha ao simular paste — CGEvent retornou nil. Texto permanece no clipboard.")
        }

        // Só arma o contador quando o paste de fato foi disparado. Antes, o
        // contador era setado no início e permanecia armado mesmo com falha —
        // a próxima correção LLM mandava N backspaces num campo que nunca
        // recebeu o texto, apagando conteúdo real do usuário.
        Self.lastPastedCount = pasteOk ? text.count : 0

        return pasteOk
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
    @MainActor func replaceLastPaste(_ newText: String) async -> Bool {
        guard AXIsProcessTrusted() else {
            logger.error("Sem permissão de Acessibilidade — não é possível substituir paste")
            return false
        }

        let charsToDelete = Self.lastPastedCount
        guard charsToDelete > 0 else {
            logger.warning("replaceLastPaste: lastPastedCount = 0, nada para substituir — apenas cola novo texto")
            // Fallback: insere o novo texto normalmente (insert cuida do restore)
            return await insert(newText)
        }

        // Aguarda restauração pendente do paste original antes de fotografar,
        // para capturar o conteúdo do usuário e não a transcrição bruta.
        await Self.awaitPendingClipboardRestore()

        let pasteboard = NSPasteboard.general

        // Fotografa o conteúdo do usuário antes de sobrescrever com o texto corrigido
        let snapshot = ClipboardSnapshot.capture(from: pasteboard)

        // Re-ativa app anterior
        if let app = Self.previousApp {
            guard !app.isTerminated else {
                logger.warning("App anterior (\(app.localizedName ?? "?")) já foi encerrado — texto corrigido será colocado no clipboard")
                pasteboard.clearContents()
                pasteboard.setString(newText, forType: .string)
                // Nada foi colado no documento — desarma o contador para a
                // próxima operação não deletar conteúdo alheio.
                Self.lastPastedCount = 0
                return false
            }
            app.activate()
            logger.debug("App reativado para replaceLastPaste: \(app.localizedName ?? "?")")
        }

        // Delay para o app reativar
        try? await Task.sleep(nanoseconds: 200_000_000)

        // Envia N Backspaces para deletar o texto colado anteriormente
        guard Self.simulateBackspaces(count: charsToDelete) else {
            logger.error("replaceLastPaste: simulateBackspaces falhou. Texto corrigido será colocado no clipboard.")
            pasteboard.clearContents()
            pasteboard.setString(newText, forType: .string)
            Self.lastPastedCount = 0
            return false
        }
        logger.debug("Enviados \(charsToDelete) backspaces para substituir paste anterior")

        // Delay para o app processar os backspaces
        try? await Task.sleep(nanoseconds: 150_000_000)

        // Coloca texto corrigido no clipboard
        pasteboard.clearContents()
        pasteboard.setString(newText, forType: .string)
        let correctedChangeCount = pasteboard.changeCount

        // Delay para clipboard propagar
        try? await Task.sleep(nanoseconds: 50_000_000)
        let pasteOk = Self.simulatePaste()
        if pasteOk {
            // Devolve o conteúdo anterior do usuário após o app alvo consumir o
            // Cmd+V. Em falha, o texto corrigido fica no clipboard (TASK-010).
            Self.scheduleClipboardRestore(snapshot, to: pasteboard, ifChangeCountIs: correctedChangeCount)
        } else {
            logger.error("replaceLastPaste: simulatePaste falhou. Texto permanece no clipboard.")
        }
        Self.lastPastedCount = pasteOk ? newText.count : 0

        return pasteOk
    }

    /// Envia N eventos de Backspace (keycode 51) em sequência via CGEvent.
    /// Deleta os últimos N chars no campo de texto focado.
    private static func simulateBackspaces(count: Int) -> Bool {
        guard count > 0 else { return true }
        let source = CGEventSource(stateID: .hidSystemState)
        for _ in 0..<count {
            guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: false) else {
                logger.error("simulateBackspaces: CGEvent retornou nil")
                return false
            }
            keyDown.post(tap: .cgAnnotatedSessionEventTap)
            keyUp.post(tap: .cgAnnotatedSessionEventTap)
        }
        return true
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
