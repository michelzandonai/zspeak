import AppKit
import Foundation
import Testing
@testable import zspeak

/// Testes do snapshot/restauração do clipboard usados pelo TextInserter para
/// devolver o conteúdo do usuário após o paste automático da transcrição.
/// Usa pasteboards únicos (withUniqueName) — não toca NSPasteboard.general,
/// então roda em paralelo sem interferir em outras suítes.
@Suite("ClipboardSnapshot")
struct ClipboardSnapshotTests {

    @Test("capture + restore devolve o conteúdo original do usuário")
    func testRoundTrip() {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.setString("conteúdo do usuário", forType: .string)

        let snapshot = ClipboardSnapshot.capture(from: pasteboard)
        #expect(!snapshot.isEmpty)

        // Simula o paste da transcrição sobrescrevendo o clipboard
        pasteboard.clearContents()
        pasteboard.setString("transcrição zspeak", forType: .string)
        let changeCount = pasteboard.changeCount

        let restored = snapshot.restore(to: pasteboard, ifChangeCountIs: changeCount)
        #expect(restored)
        #expect(pasteboard.string(forType: .string) == "conteúdo do usuário")
    }

    @Test("restore preserva todos os types do item (texto + HTML)")
    func testMultipleTypesPreserved() {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString("texto plano", forType: .string)
        item.setData(Data("<b>rico</b>".utf8), forType: .html)
        pasteboard.writeObjects([item])

        let snapshot = ClipboardSnapshot.capture(from: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString("transcrição zspeak", forType: .string)
        let changeCount = pasteboard.changeCount

        #expect(snapshot.restore(to: pasteboard, ifChangeCountIs: changeCount))
        #expect(pasteboard.string(forType: .string) == "texto plano")
        #expect(pasteboard.data(forType: .html) == Data("<b>rico</b>".utf8))
    }

    @Test("restore aborta quando o changeCount mudou — conteúdo mais novo vence")
    func testRestoreSkippedWhenClipboardChanged() {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.setString("conteúdo antigo", forType: .string)

        let snapshot = ClipboardSnapshot.capture(from: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString("transcrição zspeak", forType: .string)
        let changeCountAposPaste = pasteboard.changeCount

        // Usuário copia algo novo antes da restauração disparar
        pasteboard.clearContents()
        pasteboard.setString("cópia nova do usuário", forType: .string)

        let restored = snapshot.restore(to: pasteboard, ifChangeCountIs: changeCountAposPaste)
        #expect(!restored)
        #expect(pasteboard.string(forType: .string) == "cópia nova do usuário")
    }

    @Test("snapshot vazio não apaga o clipboard — transcrição fica como fallback")
    func testEmptySnapshotDoesNotClearClipboard() {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()

        let snapshot = ClipboardSnapshot.capture(from: pasteboard)
        #expect(snapshot.isEmpty)

        pasteboard.setString("transcrição zspeak", forType: .string)
        let changeCount = pasteboard.changeCount

        let restored = snapshot.restore(to: pasteboard, ifChangeCountIs: changeCount)
        #expect(!restored)
        #expect(pasteboard.string(forType: .string) == "transcrição zspeak")
    }
}

/// Testes do agendamento de restauração no TextInserter. Serializado porque
/// mexe em estado estático compartilhado (pendingClipboardRestore, delay).
@Suite("TextInserter - restauração do clipboard", .serialized)
@MainActor
struct TextInserterClipboardRestoreTests {

    /// Executa o corpo com delay de restore curto, preservando o valor global.
    private func withShortRestoreDelay(_ body: () async throws -> Void) async rethrows {
        let original = TextInserter.clipboardRestoreDelay
        TextInserter.clipboardRestoreDelay = 10_000_000 // 10 ms
        defer {
            TextInserter.clipboardRestoreDelay = original
            TextInserter.pendingClipboardRestore = nil
        }
        try await body()
    }

    @Test("restaura o conteúdo do usuário após o delay quando nada mudou")
    func testScheduledRestoreRuns() async {
        await withShortRestoreDelay {
            let pasteboard = NSPasteboard.withUniqueName()
            pasteboard.clearContents()
            pasteboard.setString("conteúdo do usuário", forType: .string)
            let snapshot = ClipboardSnapshot.capture(from: pasteboard)

            pasteboard.clearContents()
            pasteboard.setString("transcrição zspeak", forType: .string)

            TextInserter.scheduleClipboardRestore(
                snapshot, to: pasteboard, ifChangeCountIs: pasteboard.changeCount
            )
            #expect(TextInserter.pendingClipboardRestore != nil)

            await TextInserter.awaitPendingClipboardRestore()

            #expect(pasteboard.string(forType: .string) == "conteúdo do usuário")
            #expect(TextInserter.pendingClipboardRestore == nil)
        }
    }

    @Test("não restaura se o clipboard mudou durante o delay")
    func testScheduledRestoreSkippedWhenClipboardChanged() async {
        await withShortRestoreDelay {
            let pasteboard = NSPasteboard.withUniqueName()
            pasteboard.clearContents()
            pasteboard.setString("conteúdo antigo", forType: .string)
            let snapshot = ClipboardSnapshot.capture(from: pasteboard)

            pasteboard.clearContents()
            pasteboard.setString("transcrição zspeak", forType: .string)
            let changeCountAposPaste = pasteboard.changeCount

            TextInserter.scheduleClipboardRestore(
                snapshot, to: pasteboard, ifChangeCountIs: changeCountAposPaste
            )

            // Usuário copia algo novo antes do delay expirar (síncrono no
            // MainActor — a task de restore só roda depois deste ponto)
            pasteboard.clearContents()
            pasteboard.setString("cópia nova do usuário", forType: .string)

            await TextInserter.awaitPendingClipboardRestore()

            #expect(pasteboard.string(forType: .string) == "cópia nova do usuário")
        }
    }

    @Test("snapshot vazio não agenda restauração")
    func testEmptySnapshotNotScheduled() async {
        await withShortRestoreDelay {
            TextInserter.pendingClipboardRestore = nil
            let pasteboard = NSPasteboard.withUniqueName()
            pasteboard.clearContents()
            let snapshot = ClipboardSnapshot.capture(from: pasteboard)
            #expect(snapshot.isEmpty)

            TextInserter.scheduleClipboardRestore(
                snapshot, to: pasteboard, ifChangeCountIs: pasteboard.changeCount
            )
            #expect(TextInserter.pendingClipboardRestore == nil)
        }
    }
}
