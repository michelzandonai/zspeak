import Foundation
import os

/// Fila serial de transcrição de arquivos de áudio.
///
/// Motivação: o usuário baixa vários áudios do WhatsApp de uma vez e quer
/// transcrever todos sem repetir o fluxo arquivo-a-arquivo.
///
/// Decisões de arquitetura:
/// - **Execução serial**: o ASR roda no ANE, que é recurso único. Rodar dois
///   arquivos em paralelo troca throughput por contenção — e ainda competiria
///   com a gravação por microfone.
/// - **Prefetch de transcodificação**: enquanto o item atual ocupa o ANE, o
///   próximo item que precisa de ffmpeg (.opus/.ogg do WhatsApp) já é
///   convertido para WAV na CPU. Remove a espera do ffmpeg entre itens.
/// - **Descarte de samples em modo `.plain`**: só o modo `.meeting` reproduz
///   trechos por interlocutor (`AudioFileView` → `SpeakerAudioPlayer`). Um
///   áudio de 30 min ocupa ~115 MB de `[Float]`; segurar isso para N itens
///   concluídos estouraria a memória sem nenhum uso.
@MainActor
@Observable
final class FileTranscriptionQueue {

    // MARK: - Modelo

    enum ItemStatus: Equatable {
        case pending
        case running
        case done
        case failed(String)
        case cancelled

        var isPending: Bool { self == .pending }
        var isRunning: Bool { self == .running }

        var isFinished: Bool {
            switch self {
            case .done, .failed, .cancelled: return true
            case .pending, .running: return false
            }
        }
    }

    struct Item: Identifiable {
        let id: UUID
        let url: URL
        let fileName: String
        let mode: AudioFileTranscriber.Mode
        let numSpeakers: Int?
        var status: ItemStatus = .pending
        var phase: FileTranscriptionPhase?
        var result: FileTranscriptionResult?
        var recordID: UUID?

        /// WAV já transcodificado pelo prefetch — consumido e apagado ao rodar o item.
        fileprivate var preparedURL: URL?

        /// `true` quando o arquivo de origem é temporário e pertence à fila.
        /// Apagado ao sair da lista — não antes, senão um item que falhou não
        /// poderia ser reprocessado.
        fileprivate var ownsSourceFile: Bool = false

        var errorMessage: String? {
            if case .failed(let message) = status { return message }
            return nil
        }
    }

    struct Request {
        let url: URL
        let preTranscodedURL: URL?
        let mode: AudioFileTranscriber.Mode
        let numSpeakers: Int?
    }

    struct Outcome {
        let result: FileTranscriptionResult
        let recordID: UUID?

        init(result: FileTranscriptionResult, recordID: UUID?) {
            self.result = result
            self.recordID = recordID
        }
    }

    // MARK: - Estado observável

    private(set) var items: [Item] = []

    /// ID do item em execução — a UI usa para destacar a linha ativa.
    private(set) var activeItemID: UUID?

    // MARK: - Hooks injetados (evita acoplar a fila ao AppState; facilita teste)

    /// Executa a transcrição de um item. Tipicamente `AppState.transcribeFileForQueue`.
    var transcribeHandler: (@MainActor (Request, @escaping @MainActor (FileTranscriptionPhase) -> Void) async throws -> Outcome)?

    /// Preparação obrigatória antes de rodar um item (ex.: baixar o diarizer no modo Reunião).
    var prepareForMode: (@MainActor (AudioFileTranscriber.Mode) async throws -> Void)?

    /// Chamado quando a fila esvazia com pelo menos um item processado.
    /// Recebe os IDs concluídos **nesta rodada** — itens antigos que ainda
    /// estejam na lista não entram, senão o clipboard final traria transcrição
    /// de um lote anterior.
    var onQueueFinished: (@MainActor (_ succeededIDs: [UUID], _ failed: Int) -> Void)?

    private var runnerTask: Task<Void, Never>?
    private var activeTask: Task<Outcome, Error>?
    private var prefetchTask: Task<Void, Never>?

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.zspeak",
        category: "FileTranscriptionQueue"
    )

    init() {}

    // MARK: - Consultas

    var isRunning: Bool { runnerTask != nil }

    var doneCount: Int { items.filter { $0.status == .done }.count }
    var failedCount: Int { items.filter { if case .failed = $0.status { return true }; return false }.count }

    /// Texto de todos os itens concluídos, com o nome do arquivo como cabeçalho.
    /// É o que o botão "Copiar tudo" entrega — a origem de cada trecho importa
    /// quando são 9 áudios de conversas diferentes.
    var combinedText: String {
        combinedText(for: items.filter { $0.status == .done }.map(\.id))
    }

    /// Mesma formatação, restrita a um conjunto de itens.
    func combinedText(for ids: [UUID]) -> String {
        let wanted = Set(ids)
        return items
            .filter { wanted.contains($0.id) && $0.status == .done }
            .compactMap { item -> String? in
                guard let text = item.result?.text, !text.isEmpty else { return nil }
                return "— \(item.fileName) —\n\(text)"
            }
            .joined(separator: "\n\n")
    }

    func item(id: UUID) -> Item? {
        items.first { $0.id == id }
    }

    // MARK: - Enfileiramento

    /// Adiciona arquivos à fila e inicia o processamento.
    /// Arquivos com extensão não suportada entram como `.failed` para ficarem
    /// visíveis — falhar em silêncio num lote de 9 esconde o problema.
    /// - Parameter displayNames: nome a exibir por URL, para quem enfileira um
    ///   arquivo temporário de nome opaco mas quer mostrar o original.
    /// - Parameter ownsSourceFiles: `true` quando os arquivos são temporários
    ///   criados para a fila e devem ser apagados ao sair da lista.
    /// - Returns: os IDs dos itens criados, na mesma ordem das URLs.
    @discardableResult
    func enqueue(
        urls: [URL],
        mode: AudioFileTranscriber.Mode,
        numSpeakers: Int? = nil,
        displayNames: [URL: String] = [:],
        ownsSourceFiles: Bool = false
    ) -> [UUID] {
        var created: [UUID] = []
        var accepted = 0

        for url in urls {
            let isSupported = AudioFileTranscriber.isSupported(url: url)
            var item = Item(
                id: UUID(),
                url: url,
                fileName: displayNames[url] ?? url.lastPathComponent,
                mode: mode,
                numSpeakers: numSpeakers
            )
            item.ownsSourceFile = ownsSourceFiles

            if !isSupported {
                let ext = url.pathExtension.lowercased()
                let supported = AudioFileTranscriber.supportedExtensions
                    .sorted()
                    .map { ".\($0)" }
                    .joined(separator: ", ")
                item.status = .failed("Formato .\(ext) não é suportado. Formatos aceitos: \(supported).")
            } else {
                accepted += 1
            }

            created.append(item.id)
            items.append(item)
        }

        if accepted > 0 { start() }
        return created
    }

    func start() {
        guard runnerTask == nil else { return }
        guard items.contains(where: { $0.status.isPending }) else { return }

        runnerTask = Task { [weak self] in
            await self?.runLoop()
            self?.runnerTask = nil
            // Entre o fim do loop e a limpeza acima existe um ponto de
            // suspensão: um `enqueue` que caia exatamente aí veria a fila
            // "rodando" e ficaria parado para sempre. Este start é o resgate.
            self?.start()
        }
    }

    // MARK: - Cancelamento e limpeza

    /// Cancela um item específico. Se for o que está rodando, aborta a task ativa.
    func cancel(itemID: UUID) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        guard !items[index].status.isFinished else { return }

        if items[index].status.isRunning {
            activeTask?.cancel()
            return  // o runLoop marca `.cancelled` ao coletar o resultado
        }

        discardPrepared(at: index)
        items[index].status = .cancelled
    }

    /// Cancela tudo — item ativo, pendentes e o prefetch em voo.
    func cancelAll() {
        prefetchTask?.cancel()
        prefetchTask = nil

        for index in items.indices where !items[index].status.isFinished {
            discardPrepared(at: index)
            if items[index].status.isPending {
                items[index].status = .cancelled
            }
        }
        activeTask?.cancel()
    }

    /// Tira um item já finalizado da lista.
    ///
    /// Usado quando o mesmo arquivo é transcrito de novo: sem isso o item
    /// anterior fica órfão — some da linha da pasta (que passa a apontar para o
    /// item novo), reaparece na aba "Anexados" como linha fantasma e ainda
    /// entra no "Copiar tudo" com texto repetido.
    func remove(itemID: UUID) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        // Item em execução não sai da lista: quem quer parar usa `cancel`.
        guard items[index].status.isFinished else { return }
        discardPrepared(at: index)
        discardSourceIfOwned(at: index)
        items.remove(at: index)
    }

    /// Remove da lista os itens já finalizados (concluídos, falhos ou cancelados).
    func clearFinished() {
        for index in items.indices where items[index].status.isFinished {
            discardPrepared(at: index)
            discardSourceIfOwned(at: index)
        }
        items.removeAll { $0.status.isFinished }
    }

    /// Zera a fila por completo (cancela o que estiver rodando).
    func reset() {
        cancelAll()
        for index in items.indices {
            discardPrepared(at: index)
            discardSourceIfOwned(at: index)
        }
        items.removeAll()
        activeItemID = nil
    }

    // MARK: - Execução

    private func runLoop() async {
        var succeededIDs: [UUID] = []
        var failed = 0

        while let index = items.firstIndex(where: { $0.status.isPending }) {
            let item = items[index]
            items[index].status = .running
            items[index].phase = .loadingSamples
            activeItemID = item.id

            // Enquanto este item ocupa o ANE, o próximo já é transcodificado na CPU.
            schedulePrefetch()

            let itemID = item.id
            let task = Task { @MainActor [weak self] () throws -> Outcome in
                guard let self else { throw CancellationError() }
                return try await self.execute(item: item)
            }
            activeTask = task
            let outcome = await task.result
            activeTask = nil
            activeItemID = nil

            guard let currentIndex = items.firstIndex(where: { $0.id == itemID }) else { continue }
            discardPrepared(at: currentIndex)

            switch outcome {
            case .success(let value):
                items[currentIndex].status = .done
                items[currentIndex].phase = nil
                items[currentIndex].recordID = value.recordID
                items[currentIndex].result = Self.trimmedForStorage(value.result, mode: item.mode)
                succeededIDs.append(itemID)

            case .failure(let error):
                items[currentIndex].phase = nil
                if Self.isCancellation(error) {
                    items[currentIndex].status = .cancelled
                } else {
                    items[currentIndex].status = .failed(error.localizedDescription)
                    failed += 1
                    Self.logger.error("Item da fila falhou: \(item.fileName, privacy: .public) — \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        prefetchTask?.cancel()
        prefetchTask = nil

        if !succeededIDs.isEmpty || failed > 0 {
            onQueueFinished?(succeededIDs, failed)
        }
    }

    private func execute(item: Item) async throws -> Outcome {
        guard let transcribeHandler else {
            throw AudioFileTranscriber.TranscriberError.transcriptionFailed("Fila sem handler de transcrição configurado.")
        }

        try await prepareForMode?(item.mode)
        try Task.checkCancellation()

        // Relê o item: o prefetch pode ter anexado o WAV depois do enfileiramento.
        let prepared = items.first { $0.id == item.id }?.preparedURL
        let request = Request(
            url: item.url,
            preTranscodedURL: prepared,
            mode: item.mode,
            numSpeakers: item.numSpeakers
        )

        let itemID = item.id
        return try await transcribeHandler(request) { [weak self] phase in
            guard let self, let index = self.items.firstIndex(where: { $0.id == itemID }) else { return }
            self.items[index].phase = phase
        }
    }

    // MARK: - Prefetch de transcodificação

    /// Transcodifica o próximo item que precisa de ffmpeg, em paralelo ao ASR.
    /// Roda um por vez: mais que isso enche o disco de WAV temporário sem ganho,
    /// já que o gargalo é o ANE.
    private func schedulePrefetch() {
        guard prefetchTask == nil else { return }
        guard FFmpegTranscoder.isAvailable else { return }
        guard let index = items.firstIndex(where: {
            $0.status.isPending && $0.preparedURL == nil && Self.needsTranscoding($0.url)
        }) else { return }

        let itemID = items[index].id
        let url = items[index].url

        prefetchTask = Task { [weak self] in
            let prepared = try? await FFmpegTranscoder.shared.transcodeToWAV(inputURL: url)
            guard let self else {
                if let prepared { FFmpegTranscoder.shared.cleanup(prepared) }
                return
            }
            self.prefetchTask = nil
            guard let prepared else { return }
            self.attach(prepared: prepared, to: itemID)
        }
    }

    private func attach(prepared: URL, to itemID: UUID) {
        guard let index = items.firstIndex(where: { $0.id == itemID }),
              !items[index].status.isFinished else {
            FFmpegTranscoder.shared.cleanup(prepared)
            return
        }
        items[index].preparedURL = prepared
    }

    private func discardSourceIfOwned(at index: Int) {
        guard index < items.count, items[index].ownsSourceFile else { return }
        try? FileManager.default.removeItem(at: items[index].url)
    }

    private func discardPrepared(at index: Int) {
        guard index < items.count, let prepared = items[index].preparedURL else { return }
        FFmpegTranscoder.shared.cleanup(prepared)
        items[index].preparedURL = nil
    }

    nonisolated static func needsTranscoding(_ url: URL) -> Bool {
        AudioFileTranscriber.ffmpegExtensions.contains(url.pathExtension.lowercased())
    }

    // MARK: - Helpers

    /// Modo `.plain` não usa os samples depois de transcrever (o WAV já foi
    /// persistido no histórico) — descartar evita segurar centenas de MB numa
    /// fila longa. Modo `.meeting` mantém: a UI reproduz trechos por interlocutor.
    nonisolated static func trimmedForStorage(
        _ result: FileTranscriptionResult,
        mode: AudioFileTranscriber.Mode
    ) -> FileTranscriptionResult {
        guard mode == .plain else { return result }
        return FileTranscriptionResult(
            text: result.text,
            segments: result.segments,
            sourceFileName: result.sourceFileName,
            durationSeconds: result.durationSeconds,
            samples: []
        )
    }

    /// Constrói um item pronto para preview/snapshot sem passar pelo pipeline.
    /// `Item` tem membros `fileprivate` (posse de arquivo temporário), então o
    /// init sintetizado não é visível de fora — esta fábrica é o caminho oficial.
    static func previewItem(
        id: UUID = UUID(),
        fileName: String,
        status: ItemStatus,
        mode: AudioFileTranscriber.Mode = .plain,
        phase: FileTranscriptionPhase? = nil,
        result: FileTranscriptionResult? = nil,
        recordID: UUID? = nil
    ) -> Item {
        var item = Item(
            id: id,
            url: URL(fileURLWithPath: "/tmp/\(fileName)"),
            fileName: fileName,
            mode: mode,
            numSpeakers: nil
        )
        item.status = status
        item.phase = phase
        item.result = result
        item.recordID = recordID
        return item
    }

    nonisolated static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError
    }
}
