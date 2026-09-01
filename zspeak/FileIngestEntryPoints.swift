import AppKit
import Foundation
import os

/// Entradas do sistema para enfileirar áudios sem abrir o app antes.
///
/// Cobre os dois caminhos nativos do Finder com seleção múltipla:
/// - **Serviços**: botão direito em N arquivos → "Transcrever com zspeak"
///   (declarado em `NSServices` no Info.plist).
/// - **Abrir com**: `application(_:open:)` recebe as N URLs de uma vez
///   (declarado em `CFBundleDocumentTypes`).
///
/// Os dois desembocam na mesma `FileTranscriptionQueue` da janela — quem
/// baixou 9 áudios do WhatsApp seleciona os 9 e manda transcrever de uma vez.
@MainActor
final class FileIngestEntryPoints: NSObject {

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.zspeak",
        category: "FileIngestEntryPoints"
    )

    private let queue: FileTranscriptionQueue
    private let presentQueueWindow: () -> Void

    init(queue: FileTranscriptionQueue, presentQueueWindow: @escaping () -> Void) {
        self.queue = queue
        self.presentQueueWindow = presentQueueWindow
        super.init()
    }

    /// Registra o provider de Serviços. `NSUpdateDynamicServices` força o
    /// sistema a reler o Info.plist — sem isso o item só aparece depois de um
    /// relogin na primeira instalação.
    func install() {
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
    }

    // MARK: - Serviços do Finder

    @objc func transcribeAudioFiles(
        _ pasteboard: NSPasteboard,
        userData: String,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]) ?? []
        let accepted = enqueue(urls: urls)
        if accepted == 0 {
            error.pointee = "Nenhum arquivo de áudio suportado na seleção." as NSString
        }
    }

    // MARK: - Abrir com / arrastar no ícone

    func handleOpen(urls: [URL]) {
        _ = enqueue(urls: urls)
    }

    // MARK: - Comum

    @discardableResult
    private func enqueue(urls: [URL]) -> Int {
        let audioURLs = urls.filter { AudioFileTranscriber.isSupported(url: $0) }
        guard !audioURLs.isEmpty else {
            Self.logger.info("Seleção sem arquivo suportado (\(urls.count, privacy: .public) itens)")
            return 0
        }

        // Ordena por nome para o lote sair na ordem que o usuário vê no Finder
        // (`1.ogg`, `2.ogg`, … em vez da ordem arbitrária do pasteboard).
        let ordered = audioURLs.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }

        queue.enqueue(urls: ordered, mode: .plain)
        presentQueueWindow()
        return ordered.count
    }
}
