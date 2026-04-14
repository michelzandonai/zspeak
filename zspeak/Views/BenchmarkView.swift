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

    var body: some View {
        Form {
            if isLoadingFixtures {
                ContentUnavailableView {
                    Label("Carregando benchmarks…", systemImage: "hourglass")
                } description: {
                    ProgressView()
                }
            } else if store.fixtures.isEmpty {
                ContentUnavailableView(
                    "Nenhuma fixture",
                    systemImage: "gauge.with.needle",
                    description: Text("Importe WAVs ou use transcrições do histórico para criar fixtures de benchmark.")
                )
            } else {
                ForEach(Array(store.fixtures.enumerated()), id: \.element.id) { index, fixture in
                    Section {
                        fixtureRow(fixture, index: index)
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
        .onDisappear { stopAudio() }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    importWAV()
                } label: {
                    Label("Importar WAV", systemImage: "square.and.arrow.down")
                }
                .disabled(isRunning)

                Button {
                    store.importFromHistory(historyStore: historyStore)
                } label: {
                    Label("Importar do Histórico", systemImage: "clock.arrow.circlepath")
                }
                .disabled(isRunning)

                Button {
                    runAll()
                } label: {
                    Label("Transcrever Todos", systemImage: "play.fill")
                }
                .disabled(isRunning || store.fixtures.isEmpty)
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
                    fixtureToDelete = nil
                }
            }
        } message: {
            Text("Esta ação não pode ser desfeita.")
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
            try? await store.runBenchmark(fixture: fixture) { samples in
                try await appState.transcribe(samples)
            }
            runningFixtureId = nil
            isRunning = false
        }
    }

    private func runAll() {
        Task {
            isRunning = true
            await store.runAll { samples in
                try await appState.transcribe(samples)
            }
            isRunning = false
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
