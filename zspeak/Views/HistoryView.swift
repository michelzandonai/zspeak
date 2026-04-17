import SwiftUI
import AVFoundation

/// Tela de histórico de transcrições
struct HistoryView: View {
    let store: TranscriptionStore

    @State private var audioPlayer: AVAudioPlayer?
    @State private var playingRecordId: UUID?
    @State private var expandedRecordId: UUID?
    @State private var recordToDelete: TranscriptionRecord?
    @State private var hoveredRecordId: UUID?
    @State private var searchText: String = ""
    // Paginação: carrega em blocos para não travar a UI com históricos grandes
    @State private var visibleCount: Int = 50

    private let pageSize: Int = 50

    // MARK: - Agrupamento

    /// Grupos fixos, na ordem de exibição. Usado como chave estável das sections.
    private enum DateGroup: Int, CaseIterable, Identifiable {
        case today = 0
        case yesterday
        case thisWeek
        case older

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .today: return "Hoje"
            case .yesterday: return "Ontem"
            case .thisWeek: return "Esta semana"
            case .older: return "Mais antigos"
            }
        }

        static func classify(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> DateGroup {
            if calendar.isDateInToday(date) { return .today }
            if calendar.isDateInYesterday(date) { return .yesterday }
            // "Esta semana" = últimos 7 dias (não semana do calendário), excluindo hoje/ontem já tratados.
            if let sevenDaysAgo = calendar.date(byAdding: .day, value: -7, to: now),
               date >= sevenDaysAgo {
                return .thisWeek
            }
            return .older
        }
    }

    // MARK: - Filtragem + agrupamento derivados

    /// Normaliza string para busca diacritic-insensitive + case-insensitive.
    private func normalize(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "pt-BR"))
    }

    /// Registros após aplicar busca. Mantém ordem original (mais recente primeiro).
    private var filteredRecords: [TranscriptionRecord] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return store.records }
        let needle = normalize(q)
        return store.records.filter { normalize($0.text).contains(needle) }
    }

    /// Registros paginados após filtro.
    private var visibleRecords: [TranscriptionRecord] {
        let all = filteredRecords
        let limit = min(visibleCount, all.count)
        return Array(all.prefix(limit))
    }

    /// Agrupa os records visíveis nos buckets de data, preservando ordem interna.
    private var groupedVisibleRecords: [(group: DateGroup, records: [TranscriptionRecord])] {
        var buckets: [DateGroup: [TranscriptionRecord]] = [:]
        for r in visibleRecords {
            buckets[DateGroup.classify(r.timestamp), default: []].append(r)
        }
        return DateGroup.allCases.compactMap { g in
            guard let records = buckets[g], !records.isEmpty else { return nil }
            return (g, records)
        }
    }

    // MARK: - Body

    var body: some View {
        Form {
            if store.records.isEmpty {
                emptyState
            } else {
                searchSection

                let filteredTotal = filteredRecords.count

                if filteredTotal == 0 {
                    Section {
                        ContentUnavailableView.search(text: searchText)
                    }
                } else {
                    ForEach(groupedVisibleRecords, id: \.group.id) { bucket in
                        Section {
                            ForEach(bucket.records) { record in
                                recordRow(record)
                                    .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                            }
                        } header: {
                            Text(bucket.group.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Rodapé de paginação: só aparece se houver mais pra mostrar
                    // OU se já estivermos mostrando tudo acima de pageSize (feedback "Mostrando todos")
                    paginationFooter(filteredTotal: filteredTotal)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Histórico")
        .onDisappear { stopAudio() }
        .onChange(of: store.records.count) { _, newCount in
            // Mantém o contador saudável se o usuário apagar itens
            if visibleCount > newCount {
                visibleCount = max(pageSize, newCount)
            }
        }
        .onChange(of: searchText) { _, _ in
            // Reset paginação ao mudar busca; hover e expansão seguem vivos.
            visibleCount = pageSize
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

    // MARK: - Empty state

    private var emptyState: some View {
        ContentUnavailableView(
            "Nenhuma transcrição",
            systemImage: "text.bubble",
            description: Text(
                "Pressione a tecla de ativação (⌘ direito, por padrão) para começar a falar. " +
                "Cada transcrição ficará salva aqui com áudio e metadados."
            )
        )
    }

    // MARK: - Busca

    @ViewBuilder
    private var searchSection: some View {
        Section {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Buscar no texto das transcrições", text: $searchText)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Buscar no histórico")
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Limpar busca")
                }
            }
        }
    }

    // MARK: - Rodapé de paginação

    @ViewBuilder
    private func paginationFooter(filteredTotal: Int) -> some View {
        let shown = min(visibleCount, filteredTotal)
        // Esconde se a lista cabe inteira dentro de uma página
        if filteredTotal > pageSize {
            Section {
                HStack {
                    if shown < filteredTotal {
                        let next = min(pageSize, filteredTotal - shown)
                        Button("Mostrar próximos \(next)") {
                            visibleCount += pageSize
                        }
                        .buttonStyle(.borderless)
                        Spacer()
                    } else {
                        Text("Mostrando todos (\(filteredTotal))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
            }
        }
    }

    // MARK: - Linha compacta de cada registro

    @ViewBuilder
    private func recordRow(_ record: TranscriptionRecord) -> some View {
        let isExpanded = expandedRecordId == record.id
        let isHovered = hoveredRecordId == record.id

        VStack(alignment: .leading, spacing: 4) {
            // Texto principal (tap expande)
            Text(record.text)
                .lineLimit(isExpanded ? nil : 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        expandedRecordId = isExpanded ? nil : record.id
                    }
                }

            // Badge "Corrigido de" — caption2, opacidade 0.7
            if let sourceID = record.sourceRecordID,
               let original = store.recordsByID[sourceID] {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.uturn.backward")
                    Text("Corrigido de: \(original.text.prefix(40))\(original.text.count > 40 ? "…" : "")")
                        .lineLimit(1)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .opacity(0.7)
            }

            // Metadata + ações na mesma linha compacta
            HStack(spacing: 8) {
                metadataLine(record)
                Spacer(minLength: 8)
                actionButtons(record)
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHovered ? Color.primary.opacity(0.06) : Color.clear)
        )
        .overlay(alignment: .bottom) {
            // Separador sutil; não aparece no hover pra reforçar o destaque
            Divider().opacity(isHovered ? 0 : 0.4)
        }
        .onHover { hovering in
            hoveredRecordId = hovering ? record.id : (hoveredRecordId == record.id ? nil : hoveredRecordId)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(for: record))
    }

    // MARK: - Metadata compacta

    @ViewBuilder
    private func metadataLine(_ record: TranscriptionRecord) -> some View {
        HStack(spacing: 10) {
            Label(formattedTimestamp(record.timestamp), systemImage: "clock")
            Label(String(format: "%.1fs", record.duration), systemImage: "waveform")
            if let app = record.targetAppName {
                Label(app, systemImage: "app")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    // MARK: - Botões de ação

    @ViewBuilder
    private func actionButtons(_ record: TranscriptionRecord) -> some View {
        HStack(spacing: 6) {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(record.text, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .help("Copiar texto")
            .accessibilityLabel("Copiar texto da transcrição")

            if record.audioFileName != nil {
                Button {
                    if playingRecordId == record.id {
                        stopAudio()
                    } else {
                        playAudio(for: record)
                    }
                } label: {
                    Image(systemName: playingRecordId == record.id ? "stop.fill" : "play.fill")
                }
                .help(playingRecordId == record.id ? "Parar áudio" : "Ouvir áudio")
                .accessibilityLabel(playingRecordId == record.id ? "Parar áudio" : "Ouvir áudio")
            }

            Button(role: .destructive) {
                recordToDelete = record
            } label: {
                Image(systemName: "trash")
            }
            .help("Apagar transcrição")
            .accessibilityLabel("Apagar transcrição")
        }
        .buttonStyle(.borderless)
        .font(.callout)
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

    private func accessibilityLabel(for record: TranscriptionRecord) -> String {
        let snippet = record.text.count > 120
            ? "\(record.text.prefix(120))…"
            : record.text
        let app = record.targetAppName.map { ", em \($0)" } ?? ""
        return "Transcrição de \(formattedTimestamp(record.timestamp)), " +
               "\(String(format: "%.1f", record.duration)) segundos\(app). \(snippet)"
    }
}
