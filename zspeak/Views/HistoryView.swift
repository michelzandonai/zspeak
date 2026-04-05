import SwiftUI
import AVFoundation

/// Tela de histórico de transcrições
struct HistoryView: View {
    let store: TranscriptionStore

    @State private var audioPlayer: AVAudioPlayer?
    @State private var playingRecordId: UUID?
    @State private var expandedRecordId: UUID?
    @State private var recordToDelete: TranscriptionRecord?

    var body: some View {
        Form {
            if store.records.isEmpty {
                ContentUnavailableView(
                    "Nenhuma transcrição",
                    systemImage: "text.bubble",
                    description: Text("As transcrições aparecerão aqui conforme você usar o zspeak.")
                )
            } else {
                ForEach(store.records) { record in
                    Section {
                        recordRow(record)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Histórico")
        .onDisappear { stopAudio() }
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

            if store.audioURL(for: record) != nil {
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
