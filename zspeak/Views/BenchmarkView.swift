import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

/// Tela de benchmark de transcrição — compara transcrições com ground truth
struct BenchmarkView: View {
    let appState: AppState
    @Bindable var store: BenchmarkStore
    let historyStore: TranscriptionStore

    @State private var isRunning = false
    @State private var runningFixtureId: UUID?
    @State private var fixtureToDelete: BenchmarkFixture?
    @State private var audioPlayer: AVAudioPlayer?
    @State private var playingFixtureId: UUID?
    @State private var isLoadingFixtures = true
    /// Cache de arquivos de áudio existentes — computado uma vez por render, evita `fileExists` por linha.
    @State private var availableAudioFiles: Set<String> = []

    // MARK: - Estado de execução em lote
    @State private var runAllTask: Task<Void, Never>?
    @State private var runAllProgress: Double = 0
    @State private var runAllCurrent: Int = 0
    @State private var runAllTotal: Int = 0

    // MARK: - Erros por fixture
    @State private var errorsById: [UUID: String] = [:]

    // MARK: - Filtros
    @State private var showOnlyHighError = false

    /// Fixtures visíveis após aplicar filtro de alto erro (> 10% WER).
    private var visibleFixtures: [(offset: Int, element: BenchmarkFixture)] {
        let all = Array(store.fixtures.enumerated())
        guard showOnlyHighError else { return all.map { ($0.offset, $0.element) } }
        return all
            .filter { _, fixture in
                guard let result = fixture.lastResult else { return false }
                let errorRate = result.wordErrorRate ?? (1 - result.accuracyScore)
                return errorRate > 0.1
            }
            .map { ($0.offset, $0.element) }
    }

    /// Métricas agregadas sobre fixtures com `lastResult` não-nil.
    private var aggregateMetrics: AggregateMetrics? {
        let evaluated = store.fixtures.compactMap { $0.lastResult }
        guard !evaluated.isEmpty else { return nil }

        let avgAcc = evaluated.map(\.accuracyScore).reduce(0, +) / Double(evaluated.count)

        let wers = evaluated.compactMap(\.wordErrorRate)
        let avgWer = wers.isEmpty ? nil : wers.reduce(0, +) / Double(wers.count)

        let cers = evaluated.compactMap(\.characterErrorRate)
        let avgCer = cers.isEmpty ? nil : cers.reduce(0, +) / Double(cers.count)

        let avgLatency = evaluated.map(\.latency).reduce(0, +) / Double(evaluated.count)

        return AggregateMetrics(
            count: evaluated.count,
            averageAccuracy: avgAcc,
            averageWER: avgWer,
            averageCER: avgCer,
            averageLatency: avgLatency
        )
    }

    var body: some View {
        Form {
            if isLoadingFixtures {
                ContentUnavailableView {
                    Label("Carregando benchmarks…", systemImage: "hourglass")
                } description: {
                    ProgressView()
                }
            } else if store.fixtures.isEmpty {
                ContentUnavailableView {
                    Label("Nenhuma fixture", systemImage: "gauge.with.needle")
                } description: {
                    Text("Importe WAVs ou use transcrições do histórico para criar fixtures de benchmark.")
                } actions: {
                    Menu {
                        Button {
                            importWAV()
                        } label: {
                            Label("Importar WAV…", systemImage: "square.and.arrow.down")
                        }
                        Button {
                            store.importFromHistory(historyStore: historyStore)
                        } label: {
                            Label("Importar do Histórico", systemImage: "clock.arrow.circlepath")
                        }
                    } label: {
                        Label("Adicionar fixture", systemImage: "plus.circle.fill")
                    }
                    .menuStyle(.borderedButton)
                    .controlSize(.large)
                }
            } else {
                // Card agregado no topo — só aparece se há resultados
                if let metrics = aggregateMetrics {
                    Section {
                        aggregateCard(metrics)
                    }
                }

                // Progresso global quando rodando "Transcrever Todos"
                if isRunning && runAllTotal > 0 {
                    Section {
                        runAllProgressView
                    }
                }

                // Filtro
                if aggregateMetrics != nil {
                    Section {
                        Toggle("Mostrar só fixtures com erro > 10%", isOn: $showOnlyHighError)
                    }
                }

                if visibleFixtures.isEmpty {
                    Section {
                        ContentUnavailableView(
                            "Nenhuma fixture com erro alto",
                            systemImage: "checkmark.seal.fill",
                            description: Text("Todas as fixtures avaliadas têm WER ≤ 10%.")
                        )
                    }
                } else {
                    ForEach(visibleFixtures, id: \.element.id) { index, fixture in
                        Section {
                            fixtureRow(fixture, index: index)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Benchmark")
        .task {
            await store.loadFixturesAsync()
            availableAudioFiles = store.availableAudioFileNames()
            isLoadingFixtures = false
        }
        .onChange(of: store.fixtures.count) {
            availableAudioFiles = store.availableAudioFileNames()
        }
        .onDisappear {
            stopAudio()
            runAllTask?.cancel()
        }
        .toolbar {
            ToolbarItemGroup {
                // Ações secundárias agrupadas em Menu "+ Adicionar"
                Menu {
                    Button {
                        importWAV()
                    } label: {
                        Label("Importar WAV…", systemImage: "square.and.arrow.down")
                    }
                    Button {
                        store.importFromHistory(historyStore: historyStore)
                    } label: {
                        Label("Importar do Histórico", systemImage: "clock.arrow.circlepath")
                    }
                } label: {
                    Label("Adicionar", systemImage: "plus")
                }
                .disabled(isRunning)

                // Ação primária isolada: Transcrever Todos / Parar
                Button {
                    if isRunning {
                        runAllTask?.cancel()
                    } else {
                        runAll()
                    }
                } label: {
                    if isRunning {
                        Label("Parar", systemImage: "stop.fill")
                    } else {
                        Label("Transcrever Todos", systemImage: "play.fill")
                    }
                }
                .keyboardShortcut(isRunning ? .cancelAction : .defaultAction)
                .disabled(!isRunning && store.fixtures.isEmpty)
            }
        }
        .alert("Apagar fixture?", isPresented: .init(
            get: { fixtureToDelete != nil },
            set: { if !$0 { fixtureToDelete = nil } }
        )) {
            Button("Cancelar", role: .cancel) { fixtureToDelete = nil }
            Button("Apagar", role: .destructive) {
                if let fixture = fixtureToDelete {
                    store.deleteFixture(fixture)
                    errorsById.removeValue(forKey: fixture.id)
                    fixtureToDelete = nil
                }
            }
        } message: {
            Text("Esta ação não pode ser desfeita.")
        }
    }

    // MARK: - Card agregado

    private struct AggregateMetrics {
        let count: Int
        let averageAccuracy: Double
        let averageWER: Double?
        let averageCER: Double?
        let averageLatency: TimeInterval
    }

    @ViewBuilder
    private func aggregateCard(_ metrics: AggregateMetrics) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Resumo agregado", systemImage: "chart.bar.doc.horizontal")
                    .font(.headline)
                Spacer()
                Text("\(metrics.count) \(metrics.count == 1 ? "fixture avaliada" : "fixtures avaliadas")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 16) {
                metricCard(
                    title: "Acurácia média",
                    value: String(format: "%.0f%%", metrics.averageAccuracy * 100),
                    icon: "checkmark.seal.fill",
                    color: accuracyColor(metrics.averageAccuracy)
                )

                if let wer = metrics.averageWER {
                    metricCard(
                        title: "WER médio",
                        value: String(format: "%.1f%%", wer * 100),
                        icon: "textformat.abc",
                        color: errorRateColor(wer)
                    )
                }

                if let cer = metrics.averageCER {
                    metricCard(
                        title: "CER médio",
                        value: String(format: "%.1f%%", cer * 100),
                        icon: "character.cursor.ibeam",
                        color: errorRateColor(cer)
                    )
                }

                metricCard(
                    title: "Latência média",
                    value: String(format: "%.0fms", metrics.averageLatency * 1000),
                    icon: "timer",
                    color: .secondary
                )
            }
        }
    }

    @ViewBuilder
    private func metricCard(title: String, value: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Progresso global

    @ViewBuilder
    private var runAllProgressView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(
                    "Transcrevendo fixture \(runAllCurrent) de \(runAllTotal)",
                    systemImage: "waveform.badge.magnifyingglass"
                )
                .font(.subheadline.weight(.medium))
                Spacer()
                Text(String(format: "%.0f%%", runAllProgress * 100))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: runAllProgress)
                .progressViewStyle(.linear)
        }
    }

    // MARK: - Linha de cada fixture

    @ViewBuilder
    private func fixtureRow(_ fixture: BenchmarkFixture, index: Int) -> some View {
        // Nome
        Text(fixture.name)
            .font(.headline)

        // Texto esperado editável — binding direto por índice evita firstIndex O(n) por linha.
        if index < store.fixtures.count {
            TextField("Texto esperado", text: $store.fixtures[index].expectedText, axis: .vertical)
                .lineLimit(1...4)
        }

        // Metadados
        HStack(spacing: 12) {
            if fixture.duration > 0 {
                Label(String(format: "%.1fs", fixture.duration), systemImage: "waveform")
            }
            Label(fixture.audioFileName, systemImage: "doc.fill")
        }
        .font(.caption)
        .foregroundStyle(.secondary)

        // Último resultado
        if let result = fixture.lastResult {
            resultSection(result)
        }

        // Mensagem de erro (se runBenchmark falhou)
        if let errorMessage = errorsById[fixture.id] {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Erro ao transcrever")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }

        // Ações
        HStack(spacing: 8) {
            if availableAudioFiles.contains(fixture.audioFileName) {
                Button {
                    if playingFixtureId == fixture.id {
                        stopAudio()
                    } else {
                        playAudio(for: fixture)
                    }
                } label: {
                    Label(
                        playingFixtureId == fixture.id ? "Parar" : "Ouvir",
                        systemImage: playingFixtureId == fixture.id ? "stop.fill" : "speaker.wave.2.fill"
                    )
                }
            }

            Button {
                runSingle(fixture)
            } label: {
                if runningFixtureId == fixture.id {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("Transcrever e comparar", systemImage: "waveform.badge.magnifyingglass")
                }
            }
            .disabled(isRunning)

            Spacer()

            Button(role: .destructive) {
                fixtureToDelete = fixture
            } label: {
                Label("Apagar", systemImage: "trash")
            }
            .disabled(isRunning)
        }
        .buttonStyle(.borderless)
    }

    // MARK: - Resultado

    @ViewBuilder
    private func resultSection(_ result: BenchmarkResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(result.transcribedText)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 12) {
                Label(String(format: "Acc %.0f%%", result.accuracyScore * 100), systemImage: "checkmark.seal")
                    .foregroundStyle(accuracyColor(result.accuracyScore))
                if let wer = result.wordErrorRate {
                    Label(String(format: "WER %.0f%%", wer * 100), systemImage: "textformat.abc")
                        .foregroundStyle(errorRateColor(wer))
                }
                if let cer = result.characterErrorRate {
                    Label(String(format: "CER %.0f%%", cer * 100), systemImage: "character.cursor.ibeam")
                        .foregroundStyle(errorRateColor(cer))
                }
                Label(String(format: "%.0fms", result.latency * 1000), systemImage: "timer")
            }
            .font(.caption)
        }
    }

    private func accuracyColor(_ value: Double) -> Color {
        if value > 0.9 { return .green }
        if value > 0.7 { return .yellow }
        return .red
    }

    private func errorRateColor(_ value: Double) -> Color {
        if value < 0.1 { return .green }
        if value < 0.3 { return .yellow }
        return .red
    }

    // MARK: - Player de áudio

    private func playAudio(for fixture: BenchmarkFixture) {
        guard let url = store.audioURL(for: fixture) else { return }
        audioPlayer?.stop()
        audioPlayer = try? AVAudioPlayer(contentsOf: url)
        audioPlayer?.play()
        playingFixtureId = fixture.id
    }

    private func stopAudio() {
        audioPlayer?.stop()
        audioPlayer = nil
        playingFixtureId = nil
    }

    // MARK: - Ações

    private func runSingle(_ fixture: BenchmarkFixture) {
        Task {
            isRunning = true
            runningFixtureId = fixture.id
            errorsById.removeValue(forKey: fixture.id)
            do {
                try await store.runBenchmark(fixture: fixture) { samples in
                    try await appState.transcribe(samples)
                }
            } catch {
                errorsById[fixture.id] = error.localizedDescription
            }
            runningFixtureId = nil
            isRunning = false
        }
    }

    private func runAll() {
        let fixturesSnapshot = store.fixtures
        guard !fixturesSnapshot.isEmpty else { return }

        runAllCurrent = 0
        runAllTotal = fixturesSnapshot.count
        runAllProgress = 0

        runAllTask = Task {
            isRunning = true
            defer {
                isRunning = false
                runningFixtureId = nil
                runAllTask = nil
            }

            for (idx, fixture) in fixturesSnapshot.enumerated() {
                if Task.isCancelled { break }

                runAllCurrent = idx + 1
                runAllProgress = Double(idx) / Double(fixturesSnapshot.count)
                runningFixtureId = fixture.id
                errorsById.removeValue(forKey: fixture.id)

                do {
                    try await store.runBenchmark(fixture: fixture) { samples in
                        try await appState.transcribe(samples)
                    }
                } catch is CancellationError {
                    break
                } catch {
                    errorsById[fixture.id] = error.localizedDescription
                }
            }

            if !Task.isCancelled {
                runAllProgress = 1
            }
        }
    }

    private func importWAV() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.wav]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            if let fileName = try? store.importWAV(from: url) {
                store.addFixture(
                    name: url.deletingPathExtension().lastPathComponent,
                    expectedText: "",
                    audioFileName: fileName,
                    duration: 0
                )
            }
        }
    }
}
