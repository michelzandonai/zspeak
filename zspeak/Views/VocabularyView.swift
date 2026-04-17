import SwiftUI

/// Tela de gerenciamento de vocabulário customizado para context biasing.
///
/// Layout:
/// - Busca no topo filtra por termo ou alias
/// - Cada termo é um `DisclosureGroup`: colapsado mostra termo + qtd aliases + badge ativo/inativo
/// - Expandido mostra aliases editáveis, slider de peso (1–20), toggle e botão apagar
/// - Autosave debounced (300ms) persiste mudanças no store e reaplica vocabulário no modelo
/// - Empty state com CTA
struct VocabularyView: View {
    let appState: AppState
    @Bindable var store: VocabularyStore

    @State private var entryToDelete: VocabularyEntry?
    @State private var applyError: String?
    @State private var searchText: String = ""
    @State private var expandedIDs: Set<UUID> = []

    /// Token incrementado a cada mutação do snapshot de entries. Usado com `.task(id:)`
    /// para disparar um único debounce de 300ms por rajada de edições.
    @State private var autosaveToken: Int = 0

    // MARK: - Body

    var body: some View {
        Form {
            if store.entries.isEmpty {
                emptyStateSection
            } else {
                ForEach(filteredIndices, id: \.self) { index in
                    entrySection(at: index)
                }

                if !filteredIndices.isEmpty && filteredIndices.count < store.entries.count {
                    Section {
                        Text("Mostrando \(filteredIndices.count) de \(store.entries.count) termos")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if filteredIndices.isEmpty && !searchText.isEmpty {
                    Section {
                        ContentUnavailableView.search(text: searchText)
                    }
                }
            }

            if let applyError {
                Section {
                    Label(applyError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Vocabulário")
        .searchable(text: $searchText, placement: .toolbar, prompt: "Buscar termo ou alias")
        .toolbar {
            ToolbarItem {
                Button {
                    addNewEntry()
                } label: {
                    Label("Adicionar Termo", systemImage: "plus")
                }
            }
        }
        .alert("Apagar termo?", isPresented: .init(
            get: { entryToDelete != nil },
            set: { if !$0 { entryToDelete = nil } }
        )) {
            Button("Cancelar", role: .cancel) { entryToDelete = nil }
            Button("Apagar", role: .destructive) {
                if let entry = entryToDelete {
                    store.deleteEntry(entry)
                    expandedIDs.remove(entry.id)
                    entryToDelete = nil
                    scheduleAutosave()
                }
            }
        } message: {
            Text("Esta ação não pode ser desfeita.")
        }
        .onChange(of: entriesFingerprint) { _, _ in
            scheduleAutosave()
        }
        .task(id: autosaveToken) {
            // Debounce: 300ms após última mutação antes de persistir e reaplicar.
            guard autosaveToken > 0 else { return }
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await persistAndReapply()
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var emptyStateSection: some View {
        Section {
            ContentUnavailableView {
                Label("Nenhum termo", systemImage: "text.book.closed")
            } description: {
                Text("Adicione termos para melhorar a precisão da transcrição.")
            } actions: {
                Button {
                    addNewEntry()
                } label: {
                    Label("Adicionar termo", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    @ViewBuilder
    private func entrySection(at index: Int) -> some View {
        let entry = store.entries[index]
        let isExpanded = Binding<Bool>(
            get: { expandedIDs.contains(entry.id) },
            set: { newValue in
                if newValue { expandedIDs.insert(entry.id) }
                else { expandedIDs.remove(entry.id) }
            }
        )

        Section {
            DisclosureGroup(isExpanded: isExpanded) {
                expandedBody(for: index)
            } label: {
                collapsedLabel(for: entry)
            }
        }
        .listRowBackground(
            isExpanded.wrappedValue
                ? RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 1)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.clear))
                : nil
        )
    }

    @ViewBuilder
    private func collapsedLabel(for entry: VocabularyEntry) -> some View {
        HStack(spacing: 8) {
            Text(entry.term.isEmpty ? "(sem nome)" : entry.term)
                .font(.body)
                .foregroundStyle(entry.term.isEmpty ? .secondary : .primary)
                .lineLimit(1)

            Spacer()

            if !entry.aliases.isEmpty {
                Text("\(entry.aliases.count) \(entry.aliases.count == 1 ? "alias" : "aliases")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            badge(isEnabled: entry.isEnabled)
        }
    }

    @ViewBuilder
    private func badge(isEnabled: Bool) -> some View {
        Text(isEnabled ? "Ativo" : "Inativo")
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(isEnabled ? Color.green.opacity(0.2) : Color.gray.opacity(0.2))
            )
            .foregroundStyle(isEnabled ? Color.green : Color.secondary)
    }

    @ViewBuilder
    private func expandedBody(for index: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Termo
            VStack(alignment: .leading, spacing: 4) {
                Text("Termo")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Termo correto", text: $store.entries[index].term)
                    .textFieldStyle(.roundedBorder)
            }

            Divider()

            // Aliases
            VStack(alignment: .leading, spacing: 6) {
                Text("Aliases")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(store.entries[index].aliases.indices, id: \.self) { aliasIndex in
                    HStack {
                        TextField("Alias", text: $store.entries[index].aliases[aliasIndex])
                            .textFieldStyle(.roundedBorder)
                        Button {
                            guard aliasIndex < store.entries[index].aliases.count else { return }
                            store.entries[index].aliases.remove(at: aliasIndex)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                }

                Button {
                    store.entries[index].aliases.append("")
                } label: {
                    Label("Adicionar alias", systemImage: "plus.circle")
                        .font(.callout)
                }
                .buttonStyle(.borderless)
            }

            Divider()

            // Peso via slider 1–20
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Peso")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.0f", store.entries[index].weight))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.primary)
                        .frame(minWidth: 24, alignment: .trailing)
                }
                Slider(
                    value: $store.entries[index].weight,
                    in: 1...20,
                    step: 1
                )
                Text("Valores maiores aumentam a probabilidade do modelo preferir este termo.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Toggle("Ativo", isOn: $store.entries[index].isEnabled)

            HStack {
                Spacer()
                Button(role: .destructive) {
                    entryToDelete = store.entries[index]
                } label: {
                    Label("Apagar", systemImage: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Ações

    /// "Fingerprint" Equatable derivado das entries, já que `VocabularyEntry` não conforma Equatable.
    /// Muda sempre que term, aliases, weight ou isEnabled mudam — cobre todas as edições inline.
    private var entriesFingerprint: String {
        store.entries.reduce(into: "") { acc, entry in
            acc += "\(entry.id.uuidString)|\(entry.term)|\(entry.isEnabled)|\(entry.weight)|\(entry.aliases.joined(separator: ","));"
        }
    }

    /// Índices dos entries que batem com a busca atual. Sem filtro → todos.
    private var filteredIndices: [Int] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else {
            return Array(store.entries.indices)
        }
        return store.entries.indices.filter { idx in
            let entry = store.entries[idx]
            if entry.term.lowercased().contains(query) { return true }
            return entry.aliases.contains { $0.lowercased().contains(query) }
        }
    }

    private func addNewEntry() {
        store.addEntry(term: "", aliases: [], weight: 10.0)
        if let newID = store.entries.last?.id {
            expandedIDs.insert(newID)
        }
        scheduleAutosave()
    }

    /// Dispara uma nova janela de debounce — `.task(id:)` reinicia com o token novo.
    private func scheduleAutosave() {
        autosaveToken &+= 1
    }

    /// Persiste no disco e reaplica o vocabulário no modelo (se estiver pronto).
    private func persistAndReapply() async {
        store.save()
        applyError = nil
        guard appState.isModelReady else { return }
        do {
            try await appState.applyVocabulary()
        } catch {
            applyError = error.localizedDescription
        }
    }
}
