import Foundation
import Observation
import os

/// Lista os áudios que chegaram na pasta de downloads, do mais novo para o mais
/// antigo, com a hora em que chegaram.
///
/// Existe porque o fluxo real do usuário é: baixar vários áudios do WhatsApp e
/// querer transcrevê-los sem caçar arquivo em janela de "Abrir". A pasta é
/// observada, então um download novo aparece na lista sozinho.
///
/// A data usada é a de **chegada na pasta** (`addedToDirectoryDateKey`), não a
/// de criação: um áudio gravado ontem e baixado agora precisa aparecer no topo,
/// porque o que o usuário lembra é de ter baixado agora.
@MainActor
@Observable
final class RecentAudioScanner {

    struct Entry: Identifiable, Equatable, Sendable {
        let url: URL
        let fileName: String
        let arrivedAt: Date
        let sizeBytes: Int64

        var id: URL { url }
    }

    static let folderKey = "recentAudio.folderBookmark"

    /// Teto da lista: a pasta de Downloads de um ano tem milhares de arquivos e
    /// varrer tudo a cada evento do sistema travaria a tela.
    nonisolated static let defaultLimit = 80

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.zspeak",
        category: "RecentAudioScanner"
    )

    private(set) var entries: [Entry] = []
    private(set) var lastScanFailed: String?

    var folderURL: URL {
        didSet {
            guard folderURL != oldValue else { return }
            defaults.set(folderURL.path, forKey: Self.folderKey)
            refresh()
            startWatching()
        }
    }

    private let defaults: UserDefaults
    private let fileManager: FileManager
    private var watcher: FolderWatcher?
    /// Em preview/snapshot a lista é injetada: varrer a pasta real de Downloads
    /// tornaria o snapshot dependente da máquina de quem roda o teste.
    private let isPreview: Bool

    /// Somente para preview e snapshot: fixa a lista e desliga disco e observador.
    init(previewEntries: [Entry]) {
        self.defaults = .standard
        self.fileManager = .default
        self.isPreview = true
        self.folderURL = URL(fileURLWithPath: "/Downloads", isDirectory: true)
        self.entries = previewEntries
    }

    init(defaults: UserDefaults = .standard, fileManager: FileManager = .default) {
        self.defaults = defaults
        self.fileManager = fileManager
        self.isPreview = false
        if let stored = defaults.string(forKey: Self.folderKey), !stored.isEmpty {
            self.folderURL = URL(fileURLWithPath: stored, isDirectory: true)
        } else {
            self.folderURL = Self.defaultFolder(fileManager: fileManager)
        }
    }

    nonisolated static func defaultFolder(fileManager: FileManager = .default) -> URL {
        fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads", isDirectory: true)
    }

    // MARK: - Varredura

    func refresh() {
        guard !isPreview else { return }
        entries = Self.scan(
            directory: folderURL,
            limit: Self.defaultLimit,
            fileManager: fileManager
        )
        lastScanFailed = fileManager.fileExists(atPath: folderURL.path)
            ? nil
            : "Pasta não encontrada: \(folderURL.path)"
    }

    /// Núcleo puro: lê a pasta e devolve os áudios ordenados do mais novo para o
    /// mais antigo. Sem estado, sem UI — é o que os testes exercitam.
    nonisolated static func scan(
        directory: URL,
        limit: Int = RecentAudioScanner.defaultLimit,
        fileManager: FileManager = .default
    ) -> [Entry] {
        let keys: [URLResourceKey] = [
            .addedToDirectoryDateKey,
            .creationDateKey,
            .contentModificationDateKey,
            .fileSizeKey,
            .isRegularFileKey,
        ]

        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else {
            return []
        }

        let supported = AudioFileTranscriber.supportedExtensions

        let found: [Entry] = contents.compactMap { url in
            guard supported.contains(url.pathExtension.lowercased()) else { return nil }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile != false else { return nil }

            return Entry(
                url: url,
                fileName: url.lastPathComponent,
                arrivedAt: arrivalDate(from: values),
                sizeBytes: Int64(values?.fileSize ?? 0)
            )
        }

        return sorted(found, limit: limit)
    }

    /// Mais novo primeiro. Empate resolvido pelo nome para a ordem não dançar
    /// entre execuções (dois downloads no mesmo segundo).
    ///
    /// Separado do `scan` porque ordenação não pode ser testada através do
    /// sistema de arquivos: a data de chegada é carimbada pelo kernel e não dá
    /// para forjá-la.
    nonisolated static func sorted(_ entries: [Entry], limit: Int = RecentAudioScanner.defaultLimit) -> [Entry] {
        Array(
            entries.sorted {
                $0.arrivedAt == $1.arrivedAt
                    ? $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending
                    : $0.arrivedAt > $1.arrivedAt
            }
            .prefix(limit)
        )
    }

    /// Prioridade deliberada: quando o arquivo entrou NA PASTA vence a data de
    /// criação, que num áudio baixado é a data original da gravação.
    nonisolated static func arrivalDate(from values: URLResourceValues?) -> Date {
        values?.addedToDirectoryDate
            ?? values?.creationDate
            ?? values?.contentModificationDate
            ?? .distantPast
    }

    // MARK: - Rótulo de data

    /// "Hoje 15:14", "Ontem 20:26", "31/08 15:14", "31/08/2025 15:14".
    /// Puro de propósito: data relativa é onde teste economiza mais tempo.
    nonisolated static func arrivalLabel(
        for date: Date,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        let time = DateFormatter()
        time.locale = locale
        time.calendar = calendar
        time.timeZone = calendar.timeZone
        time.dateFormat = "HH:mm"
        let clock = time.string(from: date)

        if calendar.isDateInToday(date) { return "Hoje \(clock)" }
        if calendar.isDateInYesterday(date) { return "Ontem \(clock)" }

        let day = DateFormatter()
        day.locale = locale
        day.calendar = calendar
        day.timeZone = calendar.timeZone
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        day.dateFormat = sameYear ? "dd/MM" : "dd/MM/yyyy"
        return "\(day.string(from: date)) \(clock)"
    }

    nonisolated static func sizeLabel(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    // MARK: - Observação da pasta

    /// Um download novo precisa aparecer sem o usuário clicar em nada.
    func startWatching() {
        guard !isPreview else { return }
        watcher = FolderWatcher(url: folderURL) { [weak self] in
            self?.refresh()
        }
    }

    func stopWatching() {
        watcher = nil
    }
}

/// Observa uma pasta e avisa quando o conteúdo muda.
///
/// O evento do sistema chega várias vezes por download (arquivo temporário
/// `.download`, renomeação, atributo). O debounce evita reescanear a pasta
/// meia dúzia de vezes por arquivo salvo.
@MainActor
final class FolderWatcher {

    private var source: DispatchSourceFileSystemObject?
    private var descriptor: CInt = -1
    private var pending: Task<Void, Never>?
    private let onChange: @MainActor () -> Void

    init?(url: URL, debounce: Duration = .milliseconds(400), onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange

        descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.scheduleRefresh(after: debounce)
        }
        let fd = descriptor
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        self.source = source
    }

    private func scheduleRefresh(after debounce: Duration) {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled, let self else { return }
            self.onChange()
        }
    }

    deinit {
        pending?.cancel()
        source?.cancel()
    }
}
