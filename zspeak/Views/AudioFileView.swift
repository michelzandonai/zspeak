import SwiftUI
import UniformTypeIdentifiers
import AppKit

/// Tela de transcrição de arquivo de áudio.
///
/// Estados: `initial` (drop zone) → `processing` (progresso) → `result` (texto/segmentos).
///
/// Decomposição (issue #27): o corpo principal orquestra o fluxo e delega cada
/// bloco para uma sub-view `private struct` coesa — `AudioFileDropZone`,
/// `AudioFileProcessingView`, `AudioFileResultView`, `DiarizerStatusSection`,
/// `SpeakersPanel`, `MeetingSegmentRow`, `AudioFileErrorView`. O `@State` fica
/// neste nível porque várias propriedades são orquestração (task, fileName,
/// recordID) e o fluxo síncrono entre elas é mais claro no owner do que num
/// `ObservableObject` separado.
struct AudioFileView: View {
    let appState: AppState
    let store: TranscriptionStore

    @State private var mode: AudioFileTranscriber.Mode = .plain
    @State private var isDropTargeted: Bool = false
    @State private var diarizerState: DiarizationManager.ModelState = .notReady
    @State private var isPreparingDiarizer: Bool = false
    /// Hint do número de interlocutores: nil = automático, ou 2/3/4/5/6
    @State private var numSpeakersHint: Int? = nil
    @State private var speakerNames: [String: String] = [:]
    /// Item da fila cujo resultado está aberto embaixo da lista.
    @State private var selectedItemID: UUID?
    @StateObject private var speakerPlayer = SpeakerAudioPlayer()

    /// Lista da pasta de downloads: é por onde o usuário pega os áudios que
    /// acabou de baixar, sem abrir janela de arquivo.
    @State private var scanner: RecentAudioScanner
    @State private var selectedRecent: Set<URL> = []

    /// Qual fonte está em foco. As abas são as DUAS ORIGENS de arquivo, não os
    /// modos de transcrição: é assim que o usuário pensa o fluxo.
    @State private var source: FileSource
    /// Liga um arquivo da pasta ao item que ele virou na fila, para a linha da
    /// pasta mostrar progresso e resultado sem duplicar a lista.
    @State private var jobsByURL: [URL: UUID] = [:]
    /// Linhas abertas mostrando o texto embaixo.
    @State private var expandedRows: Set<String>

    /// Itens injetados só para preview/snapshot — em produção fica vazio e a
    /// tela lê a fila real do `AppState`.
    private let previewItems: [FileTranscriptionQueue.Item]

    init(
        appState: AppState,
        store: TranscriptionStore,
        initialMode: AudioFileTranscriber.Mode = .plain,
        initialDropTargeted: Bool = false,
        initialDiarizerState: DiarizationManager.ModelState = .notReady,
        initialPreparingDiarizer: Bool = false,
        initialNumSpeakersHint: Int? = nil,
        initialSpeakerNames: [String: String] = [:],
        previewItems: [FileTranscriptionQueue.Item] = [],
        initialSelectedItemID: UUID? = nil,
        previewFolderEntries: [RecentAudioScanner.Entry]? = nil,
        initialSource: FileSource? = nil,
        initialExpandedRows: Set<String> = []
    ) {
        self.appState = appState
        self.store = store
        self.previewItems = previewItems
        _mode = State(initialValue: initialMode)
        _isDropTargeted = State(initialValue: initialDropTargeted)
        _diarizerState = State(initialValue: initialDiarizerState)
        _isPreparingDiarizer = State(initialValue: initialPreparingDiarizer)
        _numSpeakersHint = State(initialValue: initialNumSpeakersHint)
        _speakerNames = State(initialValue: initialSpeakerNames)
        _selectedItemID = State(initialValue: initialSelectedItemID ?? previewItems.first { $0.status == .done }?.id)
        _speakerPlayer = StateObject(wrappedValue: SpeakerAudioPlayer())
        _scanner = State(initialValue: previewFolderEntries.map { RecentAudioScanner(previewEntries: $0) }
            ?? RecentAudioScanner())
        // Com itens injetados o padrão é "Anexados": é o que o snapshot mostra.
        _source = State(initialValue: initialSource ?? (previewItems.isEmpty ? .folder : .attached))
        _expandedRows = State(initialValue: initialExpandedRows)
    }

    private var queue: FileTranscriptionQueue { appState.fileQueue }

    private var items: [FileTranscriptionQueue.Item] {
        previewItems.isEmpty ? queue.items : previewItems
    }

    private var selectedItem: FileTranscriptionQueue.Item? {
        guard let selectedItemID else { return nil }
        return items.first { $0.id == selectedItemID }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                AudioFileHeader()

                FileSourceTabs(
                    source: $source,
                    folderCount: scanner.entries.count,
                    attachedCount: attachedItems.count
                )

                ZSSectionCard {
                    sourceToolbar

                    if mode == .meeting {
                        Divider()
                        DiarizerStatusSection(
                            diarizerState: diarizerState,
                            isPreparingDiarizer: isPreparingDiarizer,
                            onPrepare: prepareDiarizer
                        )
                        SpeakersHintPicker(
                            numSpeakersHint: $numSpeakersHint,
                            isDisabled: queue.isRunning
                        )
                    }

                    Divider()

                    switch source {
                    case .folder:
                        folderRows
                    case .attached:
                        attachedRows
                    }
                }

                if mode == .meeting, let segments = selectedItem?.result?.segments, !segments.isEmpty {
                    detailSection
                }
            }
            .padding(ZSDesign.pagePadding)
        }
        .zsAppSurface()
        .navigationTitle("Transcrever Arquivo")
        .onAppear {
            scanner.refresh()
            scanner.startWatching()
        }
        .onDisappear { scanner.stopWatching() }
        // Drop na janela inteira: com a fila já preenchida não sobra área de
        // drop zone, e arrastar mais um lote é a ação mais comum aqui.
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
        .task(id: mode) {
            if mode == .meeting {
                await refreshDiarizerState()
            }
        }
        .onChange(of: queue.doneCount) { _, _ in
            // Em lote, mostra sempre o resultado mais recente — o usuário
            // acompanha a fila andando sem precisar clicar em cada linha.
            if let last = queue.items.last(where: { $0.status == .done }) {
                select(itemID: last.id)
            }
        }
    }

    /// Detalhe do item selecionado: progresso (quando é o único da fila),
    /// resultado, ou erro.
    @ViewBuilder
    private var detailSection: some View {
        if items.count == 1, let only = items.first, only.status.isRunning {
            AudioFileProcessingView(
                phase: only.phase ?? .loadingSamples,
                fileName: only.fileName,
                onCancel: { queue.cancel(itemID: only.id) }
            )
        } else if let selected = selectedItem {
            switch selected.status {
            case .done:
                if let result = selected.result {
                    AudioFileResultView(
                        result: result,
                        speakerNames: $speakerNames,
                        currentRecordID: selected.recordID,
                        appState: appState,
                        speakerPlayer: speakerPlayer,
                        onTranscribeAnother: openFilePicker
                    )
                }
            case .failed(let message):
                AudioFileErrorView(
                    message: message,
                    onRetry: { retry(selected) }
                )
            case .pending, .running, .cancelled:
                EmptyView()
            }
        }
    }

    // MARK: - Ações

    private func select(itemID: UUID) {
        guard selectedItemID != itemID else { return }
        speakerPlayer.stop()
        selectedItemID = itemID
        speakerNames = Self.defaultSpeakerNames(for: items.first { $0.id == itemID }?.result)
    }

    /// Nomes iniciais dos interlocutores (id → id) para o painel renderizar.
    private static func defaultSpeakerNames(for result: FileTranscriptionResult?) -> [String: String] {
        guard let segments = result?.segments else { return [:] }
        var names: [String: String] = [:]
        for id in Set(segments.map(\.speakerId)) { names[id] = id }
        return names
    }

    /// Reenfileira um item. O arquivo de origem continua em disco justamente
    /// para isto — os temporários da fila só são apagados ao sair da lista.
    private func retry(_ item: FileTranscriptionQueue.Item) {
        let ids = queue.enqueue(urls: [item.url], mode: item.mode, numSpeakers: item.numSpeakers)
        if let first = ids.first { select(itemID: first) }
    }

    private func clearFinished() {
        let removedSelection = selectedItem?.status.isFinished ?? false
        queue.clearFinished()
        if removedSelection {
            selectedItemID = nil
            speakerNames = [:]
            speakerPlayer.stop()
        }
    }

    private func copyAll() {
        let text = queue.combinedText
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Diarizer lifecycle

    private func refreshDiarizerState() async {
        guard let diarizer = appState.diarizationManager else {
            diarizerState = .error("DiarizationManager não configurado")
            return
        }
        diarizerState = await diarizer.modelState
    }

    /// Polling do modelState do diarizer enquanto está em .preparing — atualiza
    /// UI a cada 400ms.
    ///
    /// Nota (issue #27): `DiarizationManager` é um `actor` hoje, sem API
    /// `@Observable` exposta. Quando evoluirmos o manager para expor
    /// `modelState` como stream observável (AsyncSequence ou @Observable),
    /// este polling pode ser substituído por `for await state in ...`.
    private func startDiarizerStatePolling() {
        Task {
            while isPreparingDiarizer {
                await refreshDiarizerState()
                try? await Task.sleep(nanoseconds: 400_000_000) // 400ms
            }
            // Atualização final ao sair do loop
            await refreshDiarizerState()
        }
    }

    private func prepareDiarizer() {
        guard let diarizer = appState.diarizationManager else { return }
        isPreparingDiarizer = true
        diarizerState = .preparing(progress: 0)
        startDiarizerStatePolling()
        Task {
            do {
                try await diarizer.prepare()
                diarizerState = .ready
            } catch {
                diarizerState = .error(error.localizedDescription)
            }
            isPreparingDiarizer = false
        }
    }

    // MARK: - File handling

    // MARK: - Fontes e linhas

    /// Itens da fila que NÃO vieram da lista da pasta — ou seja, o que o
    /// usuário anexou pelo seletor, arrastando ou pelo Finder.
    private var attachedItems: [FileTranscriptionQueue.Item] {
        let fromFolder = Set(jobsByURL.values)
        return items.filter { !fromFolder.contains($0.id) }
    }

    @ViewBuilder
    private var sourceToolbar: some View {
        HStack(spacing: 10) {
            if source == .folder {
                Text(scanner.folderURL.lastPathComponent)
                    .font(.caption)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    .foregroundStyle(.secondary)
                Button("Atualizar") { scanner.refresh() }
                    .controlSize(.small)
                Button("Trocar pasta", action: chooseWatchedFolder)
                    .controlSize(.small)
                Button("Abrir no Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([scanner.folderURL])
                }
                .controlSize(.small)
            } else {
                Button("Adicionar arquivos...", action: openFilePicker)
                    .controlSize(.small)
                if !attachedItems.isEmpty {
                    Button("Copiar tudo", action: copyAll).controlSize(.small)
                    Button("Limpar concluídos", action: clearFinished).controlSize(.small)
                }
            }

            Spacer()

            Picker("Modo", selection: $mode) {
                Text("Texto corrido").tag(AudioFileTranscriber.Mode.plain)
                Text("Reunião").tag(AudioFileTranscriber.Mode.meeting)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 210)
            .disabled(queue.isRunning)
        }
    }

    @ViewBuilder
    private var folderRows: some View {
        if let problem = scanner.lastScanFailed {
            Label(problem, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
        } else if scanner.entries.isEmpty {
            Text("Nenhum áudio nesta pasta ainda. Baixe um áudio e ele aparece aqui sozinho.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            VStack(spacing: 0) {
                ForEach(scanner.entries) { entry in
                    FileRow(
                        title: entry.fileName,
                        subtitle: "\(RecentAudioScanner.arrivalLabel(for: entry.arrivedAt)) · \(RecentAudioScanner.sizeLabel(entry.sizeBytes))",
                        item: jobsByURL[entry.url].flatMap { id in items.first { $0.id == id } },
                        isSelected: selectedRecent.contains(entry.url),
                        isExpanded: expandedRows.contains(entry.url.path),
                        showsSelection: true,
                        onToggleSelection: { toggleRecent(entry.url) },
                        onTranscribe: { enqueueRecent([entry.url]) },
                        onToggleExpanded: { toggleExpanded(entry.url.path) },
                        onCancel: { cancelJob(for: entry.url) }
                    )
                    if entry.id != scanner.entries.last?.id { Divider().opacity(0.4) }
                }
            }

            if !selectedRecent.isEmpty {
                Divider()
                HStack {
                    Text("\(selectedRecent.count) selecionado\(selectedRecent.count == 1 ? "" : "s")")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Transcrever selecionados") { enqueueRecent(Array(selectedRecent)) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }
        }
    }

    @ViewBuilder
    private var attachedRows: some View {
        if attachedItems.isEmpty {
            AudioFileDropZone(isDropTargeted: isDropTargeted, onPickFiles: openFilePicker)
        } else {
            VStack(spacing: 0) {
                ForEach(attachedItems) { item in
                    FileRow(
                        title: item.fileName,
                        subtitle: item.phase.map(zsPhaseDescription) ?? "Anexado",
                        item: item,
                        isSelected: false,
                        isExpanded: expandedRows.contains(item.id.uuidString),
                        showsSelection: false,
                        onToggleSelection: {},
                        onTranscribe: { retry(item) },
                        onToggleExpanded: { toggleExpanded(item.id.uuidString) },
                        onCancel: { queue.cancel(itemID: item.id) }
                    )
                    if item.id != attachedItems.last?.id { Divider().opacity(0.4) }
                }
            }
        }
    }

    private func toggleExpanded(_ key: String) {
        if expandedRows.contains(key) {
            expandedRows.remove(key)
        } else {
            expandedRows.insert(key)
        }
    }

    private func cancelJob(for url: URL) {
        guard let id = jobsByURL[url] else { return }
        queue.cancel(itemID: id)
    }

    // MARK: - Áudios recentes da pasta

    private func toggleRecent(_ url: URL) {
        if selectedRecent.contains(url) {
            selectedRecent.remove(url)
        } else {
            selectedRecent.insert(url)
        }
    }

    /// Enfileira preservando a ordem da lista (mais novo primeiro) — enfileirar
    /// na ordem do `Set` faria o lote sair embaralhado.
    private func enqueueRecent(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let chosen = Set(urls)
        let ordered = scanner.entries.map(\.url).filter { chosen.contains($0) }
        let finalOrder = ordered.isEmpty ? urls : ordered

        // "Transcrever de novo" no mesmo arquivo: o item da rodada anterior sai
        // da fila antes, senão o vínculo abaixo o deixa órfão e ele reaparece
        // como linha fantasma na aba "Anexados".
        for url in finalOrder {
            if let previous = jobsByURL[url] { queue.remove(itemID: previous) }
        }

        let ids = queue.enqueue(urls: finalOrder, mode: mode, numSpeakers: numSpeakersHint)
        // Guarda o vínculo para a linha da pasta mostrar progresso e texto sem
        // o arquivo aparecer duplicado na aba "Anexados".
        for (url, id) in zip(finalOrder, ids) {
            jobsByURL[url] = id
            expandedRows.insert(url.path)
        }
        selectedRecent.subtract(chosen)
    }

    private func chooseWatchedFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Monitorar"
        panel.message = "Escolha a pasta onde seus áudios são baixados."
        panel.directoryURL = scanner.folderURL

        if panel.runModal() == .OK, let url = panel.url {
            scanner.folderURL = url
            selectedRecent.removeAll()
        }
    }

    private func openFilePicker() {
        let panel = NSOpenPanel()
        // Seleção múltipla: o caso real é baixar vários áudios do WhatsApp de
        // uma vez e transcrever o lote inteiro.
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Transcrever"
        panel.message = "Selecione um ou mais arquivos de áudio ou vídeo."

        // Permite todos os formatos aceitáveis + audio genérico (fallback)
        var types: [UTType] = [.audio]
        for ext in AudioFileTranscriber.supportedExtensions {
            if let ut = UTType(filenameExtension: ext) {
                types.append(ut)
            }
        }
        panel.allowedContentTypes = types

        if panel.runModal() == .OK, !panel.urls.isEmpty {
            enqueue(urls: panel.urls)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }

        // `loadObject` resolve cada provider por callback e fora de ordem; o
        // coletor junta tudo e só então enfileira, preservando a ordem em que
        // os arquivos foram arrastados.
        let collector = DroppedURLCollector(expected: providers.count) { urls in
            enqueue(urls: urls)
        }
        for (index, provider) in providers.enumerated() {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                Task { @MainActor in
                    collector.set(url, at: index)
                }
            }
        }
        return true
    }

    private func enqueue(urls: [URL]) {
        guard !urls.isEmpty else { return }
        let ids = queue.enqueue(urls: urls, mode: mode, numSpeakers: numSpeakersHint)
        // Foca o primeiro item novo para o detalhe não continuar preso num
        // resultado antigo enquanto o lote roda.
        if let first = ids.first, urls.count == 1 {
            select(itemID: first)
        }
    }
}

/// Junta URLs resolvidas de forma assíncrona por vários `NSItemProvider`,
/// preservando a ordem original, e dispara o callback quando o último chega.
@MainActor
private final class DroppedURLCollector {
    private var urls: [URL?]
    private var remaining: Int
    private let onComplete: ([URL]) -> Void

    init(expected: Int, onComplete: @escaping ([URL]) -> Void) {
        self.urls = Array(repeating: nil, count: expected)
        self.remaining = expected
        self.onComplete = onComplete
    }

    func set(_ url: URL?, at index: Int) {
        guard index < urls.count, remaining > 0 else { return }
        urls[index] = url
        remaining -= 1
        guard remaining == 0 else { return }
        onComplete(urls.compactMap { $0 })
    }
}

// MARK: - Header

private struct AudioFileHeader: View {
    var body: some View {
        ZSPageHeader(
            title: "Transcrever arquivo de áudio",
            subtitle: "Importe arquivos longos, áudios de WhatsApp e reuniões sem enviar nada para a nuvem.",
            systemImage: "waveform.badge.plus",
            tone: .accent
        ) {
            VStack(alignment: .trailing, spacing: 6) {
                ZSStatusChip(text: "Local", tone: .success, systemImage: "lock.fill")
                Text("WAV · MP3 · M4A · FLAC · OPUS")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - Drop zone

private struct AudioFileDropZone: View {
    /// Só visual: o `onDrop` fica na janela inteira (ver `AudioFileView.body`).
    let isDropTargeted: Bool
    let onPickFiles: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform.badge.plus")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(isDropTargeted ? Color.accentColor : .secondary)
                .frame(width: 68, height: 68)
                .background(
                    RoundedRectangle(cornerRadius: ZSDesign.radius)
                        .fill((isDropTargeted ? Color.accentColor : Color.secondary).opacity(0.10))
                )

            Text("Arraste os arquivos de áudio aqui")
                .font(.title3.weight(.semibold))

            Text("Pode soltar vários de uma vez — eles entram numa fila e são transcritos em sequência.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button(action: onPickFiles) {
                Label("Selecionar arquivos...", systemImage: "folder")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, minHeight: 240)
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: ZSDesign.radius)
                .fill(isDropTargeted ? Color.accentColor.opacity(0.10) : ZSDesign.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ZSDesign.radius)
                .strokeBorder(
                    isDropTargeted ? Color.accentColor : ZSDesign.hairline,
                    style: StrokeStyle(lineWidth: 2, dash: [8])
                )
        )
        .animation(.easeInOut(duration: 0.16), value: isDropTargeted)
    }
}

// MARK: - Fila

/// Lista da fila de transcrição: uma linha por arquivo, com status, progresso
/// e ações em lote. É o que transforma "transcrevi um áudio" em "joguei os 9
/// áudios que baixei do WhatsApp e fui fazer outra coisa".
private struct AudioFileQueueSection: View {
    let items: [FileTranscriptionQueue.Item]
    let selectedItemID: UUID?
    let isDropTargeted: Bool
    let onSelect: (UUID) -> Void
    let onCancelItem: (UUID) -> Void
    let onCancelAll: () -> Void
    let onClearFinished: () -> Void
    let onCopyAll: () -> Void
    let onAddFiles: () -> Void

    private var finishedCount: Int { items.filter { $0.status.isFinished }.count }
    private var doneCount: Int { items.filter { $0.status == .done }.count }
    private var isRunning: Bool { items.contains { $0.status.isRunning } }
    private var hasFinished: Bool { finishedCount > 0 }

    var body: some View {
        ZSSectionCard {
            HStack(alignment: .center, spacing: 10) {
                Label("Fila de transcrição", systemImage: "list.bullet.rectangle")
                    .font(.headline)

                ZSStatusChip(
                    text: "\(finishedCount)/\(items.count)",
                    tone: finishedCount == items.count ? .success : .info,
                    systemImage: isRunning ? "waveform" : nil
                )

                Spacer()

                Button(action: onAddFiles) {
                    Label("Adicionar", systemImage: "plus")
                }
                .controlSize(.small)
            }

            if items.count > 1 {
                ProgressView(value: Double(finishedCount), total: Double(items.count))
                    .progressViewStyle(.linear)
            }

            Divider()

            VStack(spacing: 0) {
                ForEach(items) { item in
                    AudioFileQueueRow(
                        item: item,
                        isSelected: item.id == selectedItemID,
                        onSelect: { onSelect(item.id) },
                        onCancel: { onCancelItem(item.id) }
                    )
                    if item.id != items.last?.id {
                        Divider().opacity(0.4)
                    }
                }
            }

            Divider()

            HStack(spacing: 10) {
                Button(action: onCopyAll) {
                    Label(doneCount > 1 ? "Copiar tudo (\(doneCount))" : "Copiar texto", systemImage: "doc.on.doc")
                }
                .controlSize(.small)
                .disabled(doneCount == 0)

                Button(action: onClearFinished) {
                    Label("Limpar concluídos", systemImage: "eraser")
                }
                .controlSize(.small)
                .disabled(!hasFinished)

                Spacer()

                if isRunning || items.contains(where: { $0.status.isPending }) {
                    Button(role: .destructive, action: onCancelAll) {
                        Label("Cancelar tudo", systemImage: "xmark.circle")
                    }
                    .controlSize(.small)
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: ZSDesign.radius)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8]))
                .opacity(isDropTargeted ? 1 : 0)
                .animation(.easeInOut(duration: 0.16), value: isDropTargeted)
                .allowsHitTesting(false)
        )
    }
}

private struct AudioFileQueueRow: View {
    let item: FileTranscriptionQueue.Item
    let isSelected: Bool
    let onSelect: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            statusIcon
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.fileName)
                    .font(.callout.weight(isSelected ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            if let progress = phaseProgress {
                Text("\(Int(progress * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if !item.status.isFinished {
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Cancelar este arquivo")
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.10) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch item.status {
        case .pending:
            Image(systemName: "clock").foregroundStyle(.secondary)
        case .running:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(ZSDesign.successAccent)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(ZSDesign.dangerAccent)
        case .cancelled:
            Image(systemName: "slash.circle").foregroundStyle(.secondary)
        }
    }

    private var phaseProgress: Double? {
        guard item.status.isRunning, let phase = item.phase else { return nil }
        switch phase {
        case .transcoding(let progress): return progress
        case .transcribing(let current, let total):
            guard total > 1 else { return nil }
            return Double(current) / Double(total)
        case .loadingSamples, .diarizing: return nil
        }
    }

    private var subtitle: String {
        switch item.status {
        case .pending:
            return "Na fila"
        case .running:
            return zsPhaseDescription(item.phase ?? .loadingSamples)
        case .done:
            let duration = zsFormatDuration(item.result?.durationSeconds ?? 0)
            let preview = (item.result?.text ?? "")
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return preview.isEmpty ? "Concluído · \(duration)" : "\(duration) · \(preview)"
        case .failed(let message):
            return message
        case .cancelled:
            return "Cancelado"
        }
    }
}

/// Texto humano da fase atual — compartilhado pela linha da fila e pelo painel
/// grande de progresso (arquivo único).
private func zsPhaseDescription(_ phase: FileTranscriptionPhase) -> String {
    switch phase {
    case .transcoding(let progress):
        if let progress {
            return "Convertendo formato de áudio... (\(Int(progress * 100))%)"
        }
        return "Convertendo formato de áudio..."
    case .loadingSamples:
        return "Carregando áudio..."
    case .diarizing(let elapsed, let estimated):
        let sub = AudioFileTranscriber.diarizingSubphase(elapsed: elapsed, estimated: estimated)
        return "\(sub) \(Int(elapsed))s de ~\(Int(estimated))s estimados"
    case .transcribing(let current, let total):
        if total > 1 {
            return "Transcrevendo \(current) de \(total)..."
        }
        return "Transcrevendo..."
    }
}

private func zsFormatDuration(_ seconds: Double) -> String {
    let total = Int(seconds.rounded())
    return String(format: "%d:%02d", total / 60, total % 60)
}

// MARK: - Processing

private struct AudioFileProcessingView: View {
    let phase: FileTranscriptionPhase
    let fileName: String
    let onCancel: () -> Void

    var body: some View {
        ZSSectionCard {
            VStack(spacing: 18) {
                ZSIconBadge(systemImage: "waveform.badge.magnifyingglass", tone: .accent)

                VStack(spacing: 5) {
                    Text(phaseDescription)
                        .font(.headline)
                        .multilineTextAlignment(.center)

                    if !fileName.isEmpty {
                        Text(fileName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                if let progress = phaseProgress {
                    VStack(spacing: 7) {
                        ProgressView(value: progress, total: 1.0)
                            .progressViewStyle(.linear)
                            .frame(maxWidth: 420)
                        Text("\(Int(progress * 100))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.large)
                }

                Button(role: .destructive, action: onCancel) {
                    Label("Cancelar", systemImage: "xmark.circle")
                }
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, minHeight: 260)
        }
    }

    /// Progresso 0.0-1.0 da fase atual, ou nil se indeterminado
    private var phaseProgress: Double? {
        switch phase {
        case .transcoding(let progress):
            return progress
        case .transcribing(let current, let total):
            guard total > 0 else { return nil }
            return Double(current) / Double(total)
        case .loadingSamples, .diarizing:
            return nil
        }
    }

    private var phaseDescription: String { zsPhaseDescription(phase) }
}

// MARK: - Result

private struct AudioFileResultView: View {
    let result: FileTranscriptionResult
    @Binding var speakerNames: [String: String]
    let currentRecordID: UUID?
    let appState: AppState
    @ObservedObject var speakerPlayer: SpeakerAudioPlayer
    let onTranscribeAnother: () -> Void

    var body: some View {
        ZSSectionCard {
            HStack(alignment: .center, spacing: 12) {
                ZSIconBadge(systemImage: result.segments?.isEmpty == false ? "person.2.wave.2" : "text.alignleft", tone: .success)

                VStack(alignment: .leading, spacing: 3) {
                    Text(result.sourceFileName)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 8) {
                        ZSStatusChip(text: String(format: "%.1fs", result.durationSeconds), tone: .neutral, systemImage: "clock")
                        ZSStatusChip(text: (result.segments?.count).map { "\($0) segmentos" } ?? "Texto corrido", tone: .info)
                    }
                }
                Spacer()
                Button(action: onTranscribeAnother) {
                    Label("Transcrever outro", systemImage: "arrow.counterclockwise")
                }
            }

            if let segments = result.segments, !segments.isEmpty {
                SpeakersPanel(
                    result: result,
                    segments: segments,
                    speakerNames: $speakerNames,
                    currentRecordID: currentRecordID,
                    appState: appState,
                    speakerPlayer: speakerPlayer
                )
            }

            HStack(spacing: 8) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(exportedText(for: result, speakerNames: speakerNames), forType: .string)
                } label: {
                    Label("Copiar", systemImage: "doc.on.doc")
                }

                Button {
                    saveTxt(result: result, speakerNames: speakerNames)
                } label: {
                    Label("Baixar .txt", systemImage: "square.and.arrow.down")
                }

                if !appState.lastTranscription.isEmpty {
                    Button {
                        appState.applyPrompt()
                    } label: {
                        Label("Aplicar prompt LLM", systemImage: "sparkles")
                    }
                    .disabled(appState.isApplyingPrompt)
                }
                Spacer()
            }

            Divider()

            if let segments = result.segments, !segments.isEmpty {
                MeetingResultView(segments: segments, speakerNames: speakerNames)
            } else {
                PlainResultView(text: result.text)
            }
        }
    }

    private func saveTxt(result: FileTranscriptionResult, speakerNames: [String: String]) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = URL(fileURLWithPath: result.sourceFileName)
            .deletingPathExtension()
            .lastPathComponent + ".txt"
        panel.canCreateDirectories = true

        if panel.runModal() == .OK, let url = panel.url {
            try? exportedText(for: result, speakerNames: speakerNames).write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - Speakers panel (modo Reunião)

private struct SpeakersPanel: View {
    let result: FileTranscriptionResult
    let segments: [TranscribedSegment]
    @Binding var speakerNames: [String: String]
    let currentRecordID: UUID?
    let appState: AppState
    @ObservedObject var speakerPlayer: SpeakerAudioPlayer

    var body: some View {
        let speakerIds = Array(Set(segments.map(\.speakerId))).sorted()
        VStack(alignment: .leading, spacing: 10) {
            Label("Interlocutores", systemImage: "person.2.fill")
                .font(.subheadline.weight(.semibold))
            VStack(spacing: 6) {
                ForEach(speakerIds, id: \.self) { speakerId in
                    SpeakerRow(
                        speakerId: speakerId,
                        result: result,
                        segments: segments,
                        speakerNames: $speakerNames,
                        currentRecordID: currentRecordID,
                        appState: appState,
                        speakerPlayer: speakerPlayer
                    )
                }
            }
            .padding(10)
            .background(ZSDesign.raisedBackground, in: RoundedRectangle(cornerRadius: ZSDesign.compactRadius))
            .overlay(
                RoundedRectangle(cornerRadius: ZSDesign.compactRadius)
                    .strokeBorder(ZSDesign.hairline)
            )
        }
    }
}

private struct SpeakerRow: View {
    let speakerId: String
    let result: FileTranscriptionResult
    let segments: [TranscribedSegment]
    @Binding var speakerNames: [String: String]
    let currentRecordID: UUID?
    let appState: AppState
    @ObservedObject var speakerPlayer: SpeakerAudioPlayer

    var body: some View {
        let isPlaying = speakerPlayer.playingSpeakerId == speakerId
        let nameBinding = Binding<String>(
            get: { speakerNames[speakerId] ?? speakerId },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                speakerNames[speakerId] = trimmed.isEmpty ? speakerId : trimmed
                if let id = currentRecordID {
                    appState.updateSpeakerNames(recordID: id, names: speakerNames)
                }
            }
        )
        HStack(spacing: 8) {
            Button {
                if isPlaying {
                    speakerPlayer.stop()
                } else {
                    let snippet = SpeakerSnippetBuilder.buildSnippet(
                        samples: result.samples,
                        segments: segments,
                        speakerId: speakerId
                    )
                    if !snippet.isEmpty {
                        speakerPlayer.play(samples: snippet, for: speakerId)
                    }
                }
            } label: {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.title3)
                    .foregroundStyle(colorForSpeaker(speakerId))
            }
            .buttonStyle(.plain)

            TextField(speakerId, text: nameBinding)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)

            Spacer()
        }
    }
}

// MARK: - Plain + Meeting views

private struct PlainResultView: View {
    let text: String

    var body: some View {
        ScrollView {
            Text(text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .frame(minHeight: 280)
        .background(ZSDesign.raisedBackground, in: RoundedRectangle(cornerRadius: ZSDesign.radius))
        .overlay(
            RoundedRectangle(cornerRadius: ZSDesign.radius)
                .strokeBorder(ZSDesign.hairline)
        )
    }
}

private struct MeetingResultView: View {
    let segments: [TranscribedSegment]
    let speakerNames: [String: String]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(segments) { segment in
                    MeetingSegmentRow(segment: segment, speakerNames: speakerNames)
                }
            }
            .padding()
        }
        .frame(minHeight: 280)
        .background(ZSDesign.raisedBackground, in: RoundedRectangle(cornerRadius: ZSDesign.radius))
        .overlay(
            RoundedRectangle(cornerRadius: ZSDesign.radius)
                .strokeBorder(ZSDesign.hairline)
        )
    }
}

private struct MeetingSegmentRow: View {
    let segment: TranscribedSegment
    let speakerNames: [String: String]

    var body: some View {
        let displayName = speakerNames[segment.speakerId] ?? segment.speakerId
        HStack(alignment: .top, spacing: 12) {
            // Badge colorida do speaker
            Text(displayName)
                .font(.caption)
                .fontWeight(.semibold)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(colorForSpeaker(segment.speakerId).opacity(0.16), in: Capsule())
                .foregroundStyle(colorForSpeaker(segment.speakerId))
                .frame(minWidth: 80, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(AudioFileTranscriber.formatTimestamp(segment.startTimeSeconds))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospaced()

                Text(segment.text)
                    .textSelection(.enabled)
            }

            Spacer()
        }
    }
}

// MARK: - Error state

private struct AudioFileErrorView: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        ZSSectionCard {
            VStack(spacing: 14) {
                ZSIconBadge(systemImage: "exclamationmark.triangle.fill", tone: .warning)
                Text("Não foi possível transcrever")
                    .font(.headline)
                Text(message)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Button(action: onRetry) {
                    Label("Tentar de novo", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, minHeight: 240)
        }
    }
}

// MARK: - Speakers hint picker

private struct SpeakersHintPicker: View {
    @Binding var numSpeakersHint: Int?
    let isDisabled: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text("Interlocutores:")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("", selection: $numSpeakersHint) {
                Text("Automático").tag(Int?.none)
                Text("2").tag(Int?.some(2))
                Text("3").tag(Int?.some(3))
                Text("4").tag(Int?.some(4))
                Text("5").tag(Int?.some(5))
                Text("6").tag(Int?.some(6))
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(isDisabled)
        }
    }
}

// MARK: - Diarizer status

private struct DiarizerStatusSection: View {
    let diarizerState: DiarizationManager.ModelState
    let isPreparingDiarizer: Bool
    let onPrepare: () -> Void

    var body: some View {
        switch diarizerState {
        case .ready:
            Label("Modelos de diarização prontos", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)

        case .preparing(let progress):
            VStack(alignment: .leading, spacing: 6) {
                Label("Preparando modelos de diarização...", systemImage: "arrow.down.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.blue)
                ProgressView(value: progress, total: 1.0)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 360)
                Text(Self.diarizerProgressText(progress))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospaced()
            }

        case .notReady:
            VStack(alignment: .leading, spacing: 6) {
                Label("Modo Reunião precisa baixar modelos de diarização (~600 MB)", systemImage: "arrow.down.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Button(action: onPrepare) {
                    if isPreparingDiarizer {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Iniciando download...")
                        }
                    } else {
                        Text("Baixar modelos agora")
                    }
                }
                .disabled(isPreparingDiarizer)
            }

        case .error(let message):
            Label("Erro: \(message)", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.caption)
        }
    }

    /// Texto descritivo do progresso de download (ex.: "243 MB de ~600 MB · 40%")
    private static func diarizerProgressText(_ progress: Double) -> String {
        let totalMB = DiarizationManager.expectedTotalBytes / 1_000_000
        let currentMB = Int64(Double(totalMB) * progress)
        let pct = Int(progress * 100)
        return "\(currentMB) MB de ~\(totalMB) MB · \(pct)%"
    }
}

// MARK: - Helpers compartilhados

/// Texto exportado (Copiar / Baixar) usando os nomes renomeados se houver.
/// Usado por `AudioFileResultView`.
private func exportedText(for result: FileTranscriptionResult, speakerNames: [String: String]) -> String {
    guard let segments = result.segments, !segments.isEmpty else {
        return result.text
    }
    return segments.map { seg in
        let name = speakerNames[seg.speakerId] ?? seg.speakerId
        return "\(AudioFileTranscriber.formatTimestamp(seg.startTimeSeconds)) \(name): \(seg.text)"
    }.joined(separator: "\n\n")
}

/// Cores estáveis por speakerId (hash-based).
private func colorForSpeaker(_ speakerId: String) -> Color {
    let palette: [Color] = [.blue, .green, .orange, .purple, .pink, .teal, .red, .indigo]
    let hash = abs(speakerId.hashValue)
    return palette[hash % palette.count]
}


/// De onde vêm os arquivos. São as abas da tela porque é assim que o fluxo do
/// usuário se divide: o que caiu na pasta de downloads e o que ele anexou.
enum FileSource: String, CaseIterable, Identifiable {
    case folder
    case attached

    var id: String { rawValue }

    var title: String {
        switch self {
        case .folder: "Na pasta"
        case .attached: "Anexados"
        }
    }

    var icon: String {
        switch self {
        case .folder: "folder.fill"
        case .attached: "paperclip"
        }
    }
}

private struct FileSourceTabs: View {
    @Binding var source: FileSource
    let folderCount: Int
    let attachedCount: Int

    var body: some View {
        HStack(spacing: 8) {
            ForEach(FileSource.allCases) { candidate in
                let isActive = candidate == source
                Button {
                    source = candidate
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: candidate.icon)
                        Text(candidate.title)
                        Text("\(count(for: candidate))")
                            .font(.caption.monospacedDigit())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(isActive ? 0.18 : 0.10)))
                    }
                    .font(.callout.weight(isActive ? .semibold : .regular))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(isActive ? ZSDesign.accent.opacity(0.22) : Color.secondary.opacity(0.10))
                    )
                    .foregroundStyle(isActive ? Color.primary : Color.secondary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    private func count(for source: FileSource) -> Int {
        switch source {
        case .folder: folderCount
        case .attached: attachedCount
        }
    }
}

/// Linha de arquivo com o texto aparecendo embaixo, tipo dropdown.
///
/// A fonte do resultado é pequena de propósito: o pedido é caber bastante
/// transcrição na tela sem precisar abrir outra janela.
private struct FileRow: View {
    let title: String
    let subtitle: String
    let item: FileTranscriptionQueue.Item?
    let isSelected: Bool
    let isExpanded: Bool
    let showsSelection: Bool
    let onToggleSelection: () -> Void
    let onTranscribe: () -> Void
    let onToggleExpanded: () -> Void
    let onCancel: () -> Void

    private var hasResult: Bool { !(item?.result?.text ?? "").isEmpty }

    private var isRunning: Bool {
        switch item?.status {
        case .pending, .running: true
        default: false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                if showsSelection {
                    Button(action: onToggleSelection) {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(isSelected ? ZSDesign.accent : Color.secondary)
                            .imageScale(.large)
                    }
                    .buttonStyle(.plain)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(statusLine)
                        .font(.caption)
                        .foregroundStyle(statusColor)
                }

                Spacer()

                if isRunning {
                    ProgressView().controlSize(.small)
                    Button("Cancelar", action: onCancel).controlSize(.small)
                } else if hasResult {
                    Button(action: onToggleExpanded) {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    }
                    .buttonStyle(.plain)
                    .help(isExpanded ? "Recolher" : "Ver transcrição")
                    Button("Transcrever de novo", action: onTranscribe).controlSize(.small)
                } else {
                    Button("Transcrever", action: onTranscribe).controlSize(.small)
                }
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .onTapGesture {
                if hasResult { onToggleExpanded() } else if showsSelection { onToggleSelection() }
            }

            if isExpanded, let text = item?.result?.text, !text.isEmpty {
                resultBlock(text)
            }
        }
    }

    private var statusLine: String {
        switch item?.status {
        case .failed(let message): message
        case .cancelled: "Cancelado"
        case .running: item?.phase.map(zsPhaseDescription) ?? "Transcrevendo..."
        case .pending: "Na fila"
        default: subtitle
        }
    }

    private var statusColor: Color {
        switch item?.status {
        case .failed: .red
        case .cancelled: .orange
        default: .secondary
        }
    }

    @ViewBuilder
    private func resultBlock(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text)
                .font(.system(size: 11))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                Text("\(text.count) caracteres")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Copiar") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.10)))
        .padding(.bottom, 8)
    }
}
