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

    enum ViewState {
        case initial
        case processing
        case result(FileTranscriptionResult)
        case error(String)

        var isProcessing: Bool {
            if case .processing = self { return true }
            return false
        }
    }

    @State private var state: ViewState = .initial
    @State private var mode: AudioFileTranscriber.Mode = .plain
    @State private var phase: FileTranscriptionPhase = .loadingSamples
    @State private var processingTask: Task<Void, Never>?
    @State private var currentFileName: String = ""
    @State private var isDropTargeted: Bool = false
    @State private var diarizerState: DiarizationManager.ModelState = .notReady
    @State private var isPreparingDiarizer: Bool = false
    /// Hint do número de interlocutores: nil = automático, ou 2/3/4/5/6
    @State private var numSpeakersHint: Int? = nil
    @State private var speakerNames: [String: String] = [:]
    @State private var currentRecordID: UUID?
    @StateObject private var speakerPlayer = SpeakerAudioPlayer()

    init(
        appState: AppState,
        store: TranscriptionStore,
        initialState: ViewState = .initial,
        initialMode: AudioFileTranscriber.Mode = .plain,
        initialPhase: FileTranscriptionPhase = .loadingSamples,
        initialFileName: String = "",
        initialDropTargeted: Bool = false,
        initialDiarizerState: DiarizationManager.ModelState = .notReady,
        initialPreparingDiarizer: Bool = false,
        initialNumSpeakersHint: Int? = nil,
        initialSpeakerNames: [String: String] = [:],
        initialRecordID: UUID? = nil
    ) {
        self.appState = appState
        self.store = store
        _state = State(initialValue: initialState)
        _mode = State(initialValue: initialMode)
        _phase = State(initialValue: initialPhase)
        _processingTask = State(initialValue: nil)
        _currentFileName = State(initialValue: initialFileName)
        _isDropTargeted = State(initialValue: initialDropTargeted)
        _diarizerState = State(initialValue: initialDiarizerState)
        _isPreparingDiarizer = State(initialValue: initialPreparingDiarizer)
        _numSpeakersHint = State(initialValue: initialNumSpeakersHint)
        _speakerNames = State(initialValue: initialSpeakerNames)
        _currentRecordID = State(initialValue: initialRecordID)
        _speakerPlayer = StateObject(wrappedValue: SpeakerAudioPlayer())
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                AudioFileHeader()

                // Picker de modo (sempre visível)
                Picker("Modo", selection: $mode) {
                    Label("Texto corrido", systemImage: "text.alignleft").tag(AudioFileTranscriber.Mode.plain)
                    Label("Reunião", systemImage: "person.2.wave.2").tag(AudioFileTranscriber.Mode.meeting)
                }
                .pickerStyle(.segmented)
                .disabled(state.isProcessing)

                // Aviso de download de modelos de diarização + picker de speakers
                if mode == .meeting {
                    DiarizerStatusSection(
                        diarizerState: diarizerState,
                        isPreparingDiarizer: isPreparingDiarizer,
                        onPrepare: prepareDiarizer
                    )
                    SpeakersHintPicker(
                        numSpeakersHint: $numSpeakersHint,
                        isDisabled: state.isProcessing
                    )
                }

                // Conteúdo principal
                switch state {
                case .initial:
                    AudioFileDropZone(
                        isDropTargeted: $isDropTargeted,
                        onPickFile: openFilePicker,
                        onDrop: handleDrop
                    )
                case .processing:
                    AudioFileProcessingView(
                        phase: phase,
                        fileName: currentFileName,
                        onCancel: cancelProcessing
                    )
                case .result(let result):
                    AudioFileResultView(
                        result: result,
                        speakerNames: $speakerNames,
                        currentRecordID: currentRecordID,
                        appState: appState,
                        speakerPlayer: speakerPlayer,
                        onTranscribeAnother: { state = .initial }
                    )
                case .error(let message):
                    AudioFileErrorView(
                        message: message,
                        onRetry: { state = .initial }
                    )
                }
            }
            .padding()
        }
        .navigationTitle("Transcrever Arquivo")
        .task(id: mode) {
            if mode == .meeting {
                await refreshDiarizerState()
            }
        }
    }

    // MARK: - Ações

    private func cancelProcessing() {
        processingTask?.cancel()
        processingTask = nil
        state = .initial
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

    /// Garante que o diarizer está pronto antes de prosseguir. Se não estiver,
    /// dispara `prepare()` e aguarda. Lança erro se falhar.
    private func ensureDiarizerReady() async throws {
        guard let diarizer = appState.diarizationManager else {
            throw AudioFileTranscriber.TranscriberError.diarizerUnavailable
        }
        let state = await diarizer.modelState
        if case .ready = state { return }

        // Auto-dispara o download
        isPreparingDiarizer = true
        diarizerState = .preparing(progress: 0)
        startDiarizerStatePolling()
        defer { isPreparingDiarizer = false }

        try await diarizer.prepare()
        diarizerState = .ready
    }

    // MARK: - File handling

    private func openFilePicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        // Permite todos os formatos aceitáveis + audio genérico (fallback)
        var types: [UTType] = [.audio]
        for ext in AudioFileTranscriber.supportedExtensions {
            if let ut = UTType(filenameExtension: ext) {
                types.append(ut)
            }
        }
        panel.allowedContentTypes = types

        if panel.runModal() == .OK, let url = panel.url {
            startTranscription(url: url)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in
                startTranscription(url: url)
            }
        }
        return true
    }

    @MainActor
    private func startTranscription(url: URL) {
        // Valida formato
        guard AudioFileTranscriber.isSupported(url: url) else {
            state = .error("Formato .\(url.pathExtension) não é suportado.\n\nFormatos aceitos: \(AudioFileTranscriber.supportedExtensions.sorted().map { ".\($0)" }.joined(separator: ", ")).")
            return
        }

        currentFileName = url.lastPathComponent
        state = .processing
        phase = .loadingSamples

        processingTask = Task {
            do {
                // Modo Reunião: garante que o diarizer está pronto (auto-dispara download se necessário)
                if mode == .meeting {
                    try await ensureDiarizerReady()
                }

                let result = try await appState.transcribeFile(url: url, mode: mode, numSpeakers: numSpeakersHint) { newPhase in
                    self.phase = newPhase
                }
                // Inicializa speakerNames com defaults (id → id) para o painel renderizar
                if let segments = result.segments {
                    let ids = Set(segments.map(\.speakerId))
                    var initial: [String: String] = [:]
                    for id in ids { initial[id] = id }
                    speakerNames = initial
                } else {
                    speakerNames = [:]
                }
                currentRecordID = appState.lastTranscriptionRecordID
                state = .result(result)
            } catch is CancellationError {
                state = .initial
            } catch {
                if (error as NSError).domain == NSCocoaErrorDomain && (error as NSError).code == NSUserCancelledError {
                    state = .initial
                } else {
                    state = .error(error.localizedDescription)
                }
            }
            processingTask = nil
        }
    }
}

// MARK: - Header

private struct AudioFileHeader: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Transcrever arquivo de áudio")
                .font(.title2)
                .fontWeight(.semibold)
            Text("Qualquer formato: WAV, MP3, M4A, FLAC, OPUS (WhatsApp), OGG, WMA, AMR e mais.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Drop zone

private struct AudioFileDropZone: View {
    @Binding var isDropTargeted: Bool
    let onPickFile: () -> Void
    let onDrop: ([NSItemProvider]) -> Bool

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.badge.plus")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("Arraste um arquivo de áudio aqui")
                .font(.headline)

            Text("ou")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button(action: onPickFile) {
                Label("Selecionar arquivo...", systemImage: "folder")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, minHeight: 240)
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isDropTargeted ? Color.accentColor.opacity(0.1) : Color(.textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.3),
                    style: StrokeStyle(lineWidth: 2, dash: [8])
                )
        )
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            onDrop(providers)
        }
    }
}

// MARK: - Processing

private struct AudioFileProcessingView: View {
    let phase: FileTranscriptionPhase
    let fileName: String
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            // Barra determinada quando temos progresso, indeterminada caso contrário
            if let progress = phaseProgress {
                VStack(spacing: 6) {
                    ProgressView(value: progress, total: 1.0)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 360)
                    Text("\(Int(progress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospaced()
                }
            } else {
                ProgressView()
                    .progressViewStyle(.circular)
            }

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

            Button(role: .destructive, action: onCancel) {
                Label("Cancelar", systemImage: "xmark.circle")
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, minHeight: 240)
        .padding()
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

    private var phaseDescription: String {
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
        VStack(alignment: .leading, spacing: 12) {
            // Cabeçalho do resultado
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.sourceFileName)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(String(format: "%.1fs", result.durationSeconds)) · \((result.segments?.count).map { "\($0) segmentos" } ?? "texto corrido")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Transcrever outro", action: onTranscribeAnother)
            }

            // Painel de identificação de speakers (modo Reunião)
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

            // Botões de ação
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
            }

            Divider()

            // Conteúdo
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
        VStack(alignment: .leading, spacing: 6) {
            Text("Interlocutores")
                .font(.subheadline)
                .fontWeight(.semibold)
            VStack(spacing: 4) {
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
            .padding(8)
            .background(Color(.textBackgroundColor).opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 6))
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
        .background(Color(.textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
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
        .background(Color(.textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
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
                .background(colorForSpeaker(segment.speakerId).opacity(0.2), in: Capsule())
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
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Tentar outro arquivo", action: onRetry)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, minHeight: 240)
        .padding()
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
