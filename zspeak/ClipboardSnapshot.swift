import AppKit

/// Snapshot imutável do conteúdo do clipboard, usado para restaurar o que o
/// usuário tinha copiado antes do paste automático da transcrição.
///
/// A restauração é condicional ao `changeCount`: se qualquer outro app (ou o
/// próprio usuário) escreveu no clipboard depois do snapshot ser capturado,
/// o restore é abortado para não sobrescrever o conteúdo mais novo.
struct ClipboardSnapshot {

    /// Itens capturados: cada item preserva todos os seus types e dados.
    private let items: [[NSPasteboard.PasteboardType: Data]]

    /// Snapshot sem conteúdo (clipboard estava vazio na captura)
    var isEmpty: Bool { items.isEmpty }

    /// Captura o conteúdo atual do pasteboard (todos os itens e types).
    /// `data(forType:)` resolve promises lazy, então o snapshot é auto-contido
    /// mesmo que o app de origem seja encerrado depois.
    static func capture(from pasteboard: NSPasteboard) -> ClipboardSnapshot {
        let captured = (pasteboard.pasteboardItems ?? []).map { item in
            var dataByType: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                dataByType[type] = item.data(forType: type)
            }
            return dataByType
        }
        return ClipboardSnapshot(items: captured.filter { !$0.isEmpty })
    }

    /// Restaura o snapshot somente se o pasteboard ainda está no estado esperado
    /// (`changeCount` igual a `expected`) e se há algo para restaurar — snapshot
    /// vazio não apaga o clipboard, deixando a transcrição como fallback manual.
    /// Retorna true se restaurou, false se pulou.
    @discardableResult
    func restore(to pasteboard: NSPasteboard, ifChangeCountIs expected: Int) -> Bool {
        guard !items.isEmpty, pasteboard.changeCount == expected else { return false }
        let restoredItems = items.map { entry -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entry {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.clearContents()
        pasteboard.writeObjects(restoredItems)
        return true
    }
}
