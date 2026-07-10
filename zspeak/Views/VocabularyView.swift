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
    /// Modal de criação de termo — substitui o fluxo antigo que criava uma
    /// entrada vazia no fim da lista, fora da tela.
    @State private var showingNewTermSheet = false

    /// Token incrementado a cada mutação do snapshot de entries. Usado com `.task(id:)`
    /// para disparar um único debounce de 300ms por rajada de edições.
    @State private var autosaveToken: Int = 0

    init(appState: AppState, store: VocabularyStore, initialExpandedIDs: Set<UUID> = []) {
        self.appState = appState
        self.store = store
        _expandedIDs = State(initialValue: initialExpandedIDs)
    }

    // MARK: - Body

    var body: some View {
        Form {
            if store.entries.isEmpty {
                emptyStateSection
            } else {
                addTermSection

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
        .zsAppSurface()
        .navigationTitle("Vocabulário")
        .navigationSubtitle("Termos, aliases e pesos do biasing local")
        .searchable(text: $searchText, placement: .toolbar, prompt: "Buscar termo ou alias")
        .toolbar {
            ToolbarItem {
                Button {
                    showingNewTermSheet = true
                } label: {
                    Label("Adicionar Termo", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showingNewTermSheet) {
            NewVocabularyTermSheet { term, aliases, weight, context in
                addEntryFromSheet(term: term, aliases: aliases, weight: weight, context: context)
            }
        }
        .onAppear {
            // Faxina de entradas em branco criadas pelo fluxo antigo (cliques
            // repetidos em "Adicionar termo" sem feedback visual).
            if store.removeEmptyEntries() > 0 {
                scheduleAutosave()
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
                    showingNewTermSheet = true
                } label: {
                    Label("Adicionar termo", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    @ViewBuilder
    private var addTermSection: some View {
        Section {
            Button {
                showingNewTermSheet = true
            } label: {
                Label("Adicionar termo", systemImage: "plus.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
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
                collapsedLabel(for: index)
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

    /// Row colapsada: termo, badge de contexto dev, resumo (aliases · peso) e
    /// switch inline — habilita/desabilita sem precisar expandir.
    @ViewBuilder
    private func collapsedLabel(for index: Int) -> some View {
        let entry = store.entries[index]

        HStack(spacing: 8) {
            Text(entry.term.isEmpty ? "(sem nome)" : entry.term)
                .font(.body.weight(.medium))
                .foregroundStyle(entry.term.isEmpty || !entry.isEnabled ? .secondary : .primary)
                .lineLimit(1)

            if entry.context == .dev {
                ZSStatusChip(text: "Dev", tone: .info, systemImage: "terminal")
            }

            Spacer()

            Text(collapsedSummary(for: entry))
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("", isOn: $store.entries[index].isEnabled)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .accessibilityLabel(entry.isEnabled ? "Desativar termo" : "Ativar termo")
        }
    }

    private func collapsedSummary(for entry: VocabularyEntry) -> String {
        var parts: [String] = []
        if !entry.aliases.isEmpty {
            parts.append("\(entry.aliases.count) \(entry.aliases.count == 1 ? "alias" : "aliases")")
        }
        parts.append(String(format: "peso %.0f", entry.weight))
        return parts.joined(separator: " · ")
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

            // Contexto: onde o termo participa (global ou só apps de dev)
            VStack(alignment: .leading, spacing: 4) {
                Picker("Contexto", selection: $store.entries[index].context) {
                    ForEach(VocabularyEntryContext.allCases, id: \.self) { context in
                        Text(context.label).tag(context)
                    }
                }
                .pickerStyle(.segmented)
                Text("Em \"Apps de dev\", o termo só é aplicado ditando em terminal, IDE ou editor de código.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Divider()

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
    /// Muda sempre que term, aliases, weight, isEnabled ou context mudam — cobre todas as edições inline.
    private var entriesFingerprint: String {
        store.entries.reduce(into: "") { acc, entry in
            acc += "\(entry.id.uuidString)|\(entry.term)|\(entry.isEnabled)|\(entry.weight)|\(entry.context.rawValue)|\(entry.aliases.joined(separator: ","));"
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

    /// Cria a entrada a partir do modal: entra no TOPO da lista (visível de
    /// imediato) e limpa a busca para o termo novo não nascer filtrado.
    private func addEntryFromSheet(
        term: String,
        aliases: [String],
        weight: Float,
        context: VocabularyEntryContext
    ) {
        searchText = ""
        store.addEntry(term: term, aliases: aliases, weight: weight, context: context, prepend: true)
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

// MARK: - Modal de novo termo

/// Modal de criação de termo com todos os campos e validação: "Adicionar" só
/// habilita com termo preenchido — impossível criar entradas em branco.
struct NewVocabularyTermSheet: View {
    /// Callback com (termo, aliases, peso, contexto) já validados/aparados.
    let onAdd: (String, [String], Float, VocabularyEntryContext) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var term = ""
    @State private var aliasesText = ""
    @State private var weight: Float = 10
    @State private var entryContext: VocabularyEntryContext = .global

    private var trimmedTerm: String {
        term.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    ZSSettingsIcon(systemImage: "text.book.closed.fill", color: .teal, size: 32)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Novo termo")
                            .font(.headline)
                        Text("Entra no biasing do modelo e nas correções do texto transcrito.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            Section {
                TextField("Termo", text: $term, prompt: Text("ex.: Kubernetes"))
                TextField("Aliases", text: $aliasesText, prompt: Text("erros comuns, separados por vírgula"))
            } footer: {
                Text("Aliases são variações que o modelo confunde — ex.: \"cuber netes, kubernets\". O texto transcrito é corrigido para o termo.")
            }

            Section {
                HStack {
                    Text("Peso")
                    Slider(value: $weight, in: 1...20, step: 1)
                    Text(String(format: "%.0f", weight))
                        .font(.callout.monospacedDigit())
                        .frame(minWidth: 24, alignment: .trailing)
                }

                Picker("Contexto", selection: $entryContext) {
                    ForEach(VocabularyEntryContext.allCases, id: \.self) { context in
                        Text(context.label).tag(context)
                    }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("Em \"Apps de dev\", o termo só é aplicado ditando em terminal, IDE ou editor de código.")
            }

            Section {
                HStack {
                    Spacer()

                    Button("Cancelar", role: .cancel) {
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)

                    Button("Adicionar") {
                        onAdd(
                            trimmedTerm,
                            VocabularyStore.parseAliasesInput(aliasesText),
                            weight,
                            entryContext
                        )
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedTerm.isEmpty)
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
        }
        .formStyle(.grouped)
        .zsAppSurface()
        .frame(width: 440, height: 440)
    }
}
