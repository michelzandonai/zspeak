import SwiftUI
import AVFoundation

/// Tela de histórico de transcrições
struct HistoryView: View {
    let store: TranscriptionStore

    @State private var audioPlayer: AVAudioPlayer?
    @State private var playingRecordId: UUID?
    @State private var expandedRecordId: UUID?
    @State private var recordToDelete: TranscriptionRecord?
    // Pagina\u00e7\u00e3o: carrega em blocos para n\u00e3o travar a UI com hist\u00f3ricos grandes
    @State private var visibleCount: Int = 30

    private let pageSize: Int = 30

    var body: some View {
        Form {
            if store.records.isEmpty {
                ContentUnavailableView(
                    "Nenhuma transcrição",
                    systemImage: "text.bubble",
                    description: Text("As transcrições aparecerão aqui conforme você usar o zspeak.")
                )
            } else {
                let total = store.records.count
                let limit = min(visibleCount, total)
                ForEach(store.records.prefix(limit)) { record in
                    Section {
                        recordRow(record)
                    }
                }
                if limit < total {
                    Section {
                        HStack {
                            Text("Mostrando \(limit) de \(total)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Carregar mais \(min(pageSize, total - limit))") {
                                visibleCount += pageSize
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Histórico")
        .onDisappear { stopAudio() }
        .onChange(of: store.records.count) { _, newCount in
            // Mant\u00e9m o contador saud\u00e1vel se o usu\u00e1rio apagar itens
            if visibleCount > newCount {
                visibleCount = max(pageSize, newCount)
            }
        }
        .alert("Apagar transcrição?", isPresented: .init(
            get: { recordToDelete != nil },
            set: { if !$0 { recordToDelete = nil } }
        )) {
            Button("Cancelar", role: .cancel) { recordToDelete = nil }
            Button("Apagar", role: .destructive) {
                if let record = recordToDelete {
                    stopAudio()
                    store.deleteRecord(record)
                    recordToDelete = nil
                }
            }
        } message: {
            Text("Esta ação não pode ser desfeita.")
        }
    }

    // MARK: - Linha de cada registro

    @ViewBuilder
    private func recordRow(_ record: TranscriptionRecord) -> some View {
        // Texto transcrito
        VStack(alignment: .leading, spacing: 4) {
            let isExpanded = expandedRecordId == record.id
            Text(record.text)
                .lineLimit(isExpanded ? nil : 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        expandedRecordId = isExpanded ? nil : record.id
                    }
                }

            // Badge de linkagem: se este record foi gerado a partir de outro
            // Lookup O(1) via dict do store
            if let sourceID = record.sourceRecordID,
               let original = store.recordsByID[sourceID] {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.uturn.backward")
                    Text("Corrigido de: \(original.text.prefix(40))\(original.text.count > 40 ? "…" : "")")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }

        // Metadados
        HStack(spacing: 12) {
            Label(formattedTimestamp(record.timestamp), systemImage: "clock")
            Label(String(format: "%.1fs", record.duration), systemImage: "waveform")
            Label(record.modelName, systemImage: "cpu")
            if let app = record.targetAppName {
                Label(app, systemImage: "app")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)

        // Ações
        HStack(spacing: 8) {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(record.text, forType: .string)
            } label: {
                Label("Copiar", systemImage: "doc.on.doc")
            }

            // Botão "Ouvir" renderizado sempre que houver audioFileName.
            // Checagem real de existência fica no tap (playAudio), evitando I/O no render.
            if record.audioFileName != nil {
                Button {
                    if playingRecordId == record.id {
                        stopAudio()
                    } else {
                        playAudio(for: record)
                    }
                } label: {
                    Label(
                        playingRecordId == record.id ? "Parar" : "Ouvir",
                        systemImage: playingRecordId == record.id ? "stop.fill" : "play.fill"
                    )
                }
            }

            Spacer()

            Button(role: .destructive) {
                recordToDelete = record
            } label: {
                Label("Apagar", systemImage: "trash")
            }
        }
        .buttonStyle(.borderless)
    }

    // MARK: - Player de áudio

    private func playAudio(for record: TranscriptionRecord) {
        guard let url = store.audioURL(for: record) else { return }
        audioPlayer?.stop()
        audioPlayer = try? AVAudioPlayer(contentsOf: url)
        audioPlayer?.play()
        playingRecordId = record.id
    }

    private func stopAudio() {
        audioPlayer?.stop()
        audioPlayer = nil
        playingRecordId = nil
    }

    // MARK: - Formatação

    private func formattedTimestamp(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "pt-BR")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
