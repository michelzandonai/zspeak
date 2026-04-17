import SwiftUI

/// Tela de gerenciamento de prompts de correção LLM.
///
/// Layout:
/// - Toggle global "Correção LLM ativa"
/// - Seção "Modelo LLM" compacta: um único HStack com ícone + título + badge + CTA único
///   (Baixar / Carregar / Remover). Durante download, progresso determinado.
/// - Lista de prompts como `DisclosureGroup` colapsado por default; header mostra nome
///   + badge "Ativo" se ativo. Expandido exibe nome, prompt sistema, radio de ativação e apagar.
/// - Toolbar com "+" (prompt em branco) e menu de templates
/// - Autosave com debounce de 500ms
struct CorrectionPromptsView: View {
    let appState: AppState
    @Bindable var store: CorrectionPromptStore

    @State private var promptToDelete: CorrectionPrompt?
    @State private var modelState: LLMCorrectionManager.ModelState = .notDownloaded
    @State private var isBusy = false
    @State private var expandedIDs: Set<UUID> = []

    @State private var autosaveToken: Int = 0

    // MARK: - Body

    var body: some View {
        Form {
            // Toggle global
            Section {
                Toggle("Correção LLM ativa", isOn: Bindable(appState).llmCorrectionEnabled)
            }

            // Modelo LLM compacto
            Section("Modelo LLM") {
                modelRow
                if case .downloading(let progress) = modelState {
                    ProgressView(value: progress, total: 1.0)
                        .progressViewStyle(.linear)
                }
                if case .error(let message) = modelState {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }

            // Lista de prompts
            Section("Prompts") {
                if store.prompts.isEmpty {
                    ContentUnavailableView {
                        Label("Nenhum prompt", systemImage: "sparkles")
                    } description: {
                        Text("Adicione prompts para correção pós-transcrição ou use um template.")
                    } actions: {
                        Menu {
                            templateMenuItems
                        } label: {
                            Label("Usar template", systemImage: "wand.and.stars")
                        }
                        .menuStyle(.borderlessButton)
                    }
                } else {
                    ForEach(store.prompts.indices, id: \.self) { index in
                        promptRow(at: index)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Correção LLM")
        .toolbar {
            ToolbarItemGroup {
                Menu {
                    templateMenuItems
                } label: {
                    Label("Template", systemImage: "wand.and.stars")
                }

                Button {
                    addBlankPrompt()
                } label: {
                    Label("Adicionar Prompt", systemImage: "plus")
                }
            }
        }
        .alert("Apagar prompt?", isPresented: .init(
            get: { promptToDelete != nil },
            set: { if !$0 { promptToDelete = nil } }
        )) {
            Button("Cancelar", role: .cancel) { promptToDelete = nil }
            Button("Apagar", role: .destructive) {
                if let prompt = promptToDelete {
                    store.deletePrompt(prompt)
                    expandedIDs.remove(prompt.id)
                    promptToDelete = nil
                }
            }
        } message: {
            Text("Esta ação não pode ser desfeita.")
        }
        .onChange(of: store.prompts) {
            autosaveToken &+= 1
        }
        .task(id: autosaveToken) {
            guard autosaveToken > 0 else { return }
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            store.save()
        }
        .task {
            modelState = await appState.llmModelState()
        }
    }

    // MARK: - Model row

    @ViewBuilder
    private var modelRow: some View {
        HStack(spacing: 10) {
            Image(systemName: modelStateIcon)
                .foregroundStyle(modelStateColor)
                .font(.title3)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text("Qwen 2.5 3B")
                    .font(.body)
                Text(modelStateSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            modelStateBadge

            modelCTA
        }
    }

    @ViewBuilder
    private var modelStateBadge: some View {
        Text(modelStateBadgeText)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(modelStateColor.opacity(0.2))
            )
            .foregroundStyle(modelStateColor)
    }

    @ViewBuilder
    private var modelCTA: some View {
        switch modelState {
        case .notDownloaded, .error:
            Button("Baixar") { downloadModel() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isBusy)
                .accessibilityIdentifier("downloadModelButton")

        case .downloading:
            ProgressView()
                .controlSize(.small)

        case .downloaded:
            HStack(spacing: 6) {
                Button("Carregar") { loadModel() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .accessibilityIdentifier("loadModelButton")
                Button("Remover", role: .destructive) { removeModel() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("removeModelButton")
            }

        case .loading:
            ProgressView()
                .controlSize(.small)

        case .ready:
            Button("Remover", role: .destructive) { removeModel() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("removeModelButton")
        }
    }

    private var modelStateIcon: String {
        switch modelState {
        case .notDownloaded: "arrow.down.circle"
        case .downloading: "arrow.down.circle.dotted"
        case .loading: "arrow.clockwise.circle"
        case .downloaded: "checkmark.circle"
        case .ready: "checkmark.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    private var modelStateColor: Color {
        switch modelState {
        case .notDownloaded: .secondary
        case .downloading: .blue
        case .loading: .orange
        case .downloaded: .green
        case .ready: .green
        case .error: .red
        }
    }

    private var modelStateBadgeText: String {
        switch modelState {
        case .notDownloaded: "Não baixado"
        case .downloading(let progress): "Baixando \(Int(progress * 100))%"
        case .loading: "Carregando"
        case .downloaded: "Baixado"
        case .ready: "Pronto"
        case .error: "Erro"
        }
    }

    private var modelStateSubtitle: String {
        switch modelState {
        case .notDownloaded: "Modelo LLM para correção pós-transcrição"
        case .downloading: "Baixando pesos do HuggingFace…"
        case .loading: "Carregando na memória…"
        case .downloaded: "Pronto para carregar"
        case .ready: "Pronto para corrigir transcrições"
        case .error: "Falha — tente novamente"
        }
    }

    // MARK: - Prompt row

    @ViewBuilder
    private func promptRow(at index: Int) -> some View {
        let prompt = store.prompts[index]
        let isExpanded = Binding<Bool>(
            get: { expandedIDs.contains(prompt.id) },
            set: { newValue in
                if newValue { expandedIDs.insert(prompt.id) }
                else { expandedIDs.remove(prompt.id) }
            }
        )

        DisclosureGroup(isExpanded: isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Nome")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Nome", text: $store.prompts[index].name)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Instrução do sistema")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $store.prompts[index].systemPrompt)
                        .frame(minHeight: 60, maxHeight: 100)
                        .font(.body)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                        )
                }

                HStack {
                    Button {
                        store.setActive(prompt)
                    } label: {
                        Label(
                            prompt.isActive ? "Ativo" : "Definir como ativo",
                            systemImage: prompt.isActive ? "circle.fill" : "circle"
                        )
                        .foregroundStyle(prompt.isActive ? .green : .secondary)
                    }
                    .buttonStyle(.borderless)

                    Spacer()

                    Button(role: .destructive) {
                        promptToDelete = prompt
                    } label: {
                        Label("Apagar", systemImage: "trash")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                }
            }
            .padding(.vertical, 4)
        } label: {
            HStack(spacing: 8) {
                Text(prompt.name.isEmpty ? "(sem nome)" : prompt.name)
                    .font(.body)
                    .foregroundStyle(prompt.name.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                Spacer()
                if prompt.isActive {
                    Text("Ativo")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.green.opacity(0.2)))
                        .foregroundStyle(.green)
                }
            }
        }
    }

    // MARK: - Templates

    @ViewBuilder
    private var templateMenuItems: some View {
        ForEach(CorrectionPromptTemplate.all) { template in
            Button(template.name) {
                addFromTemplate(template)
            }
        }
    }

    private func addBlankPrompt() {
        store.addPrompt(name: "Novo prompt", systemPrompt: "")
        if let newID = store.prompts.last?.id {
            expandedIDs.insert(newID)
        }
    }

    private func addFromTemplate(_ template: CorrectionPromptTemplate) {
        store.addPrompt(name: template.name, systemPrompt: template.systemPrompt)
        if let newID = store.prompts.last?.id {
            expandedIDs.insert(newID)
        }
    }

    // MARK: - Modelo

    private func downloadModel() {
        Task {
            isBusy = true
            modelState = .downloading(progress: 0)
            modelState = await appState.downloadLLMModel()
            isBusy = false
        }
    }

    private func loadModel() {
        Task {
            isBusy = true
            modelState = .loading
            modelState = await appState.loadLLMModel()
            isBusy = false
        }
    }

    private func removeModel() {
        Task {
            isBusy = true
            await appState.removeLLMModel()
            modelState = .notDownloaded
            isBusy = false
        }
    }
}

// MARK: - Templates

/// Templates de prompts pré-definidos oferecidos no menu do toolbar.
private struct CorrectionPromptTemplate: Identifiable {
    let id = UUID()
    let name: String
    let systemPrompt: String

    static let all: [CorrectionPromptTemplate] = [
        CorrectionPromptTemplate(
            name: "Correção geral",
            systemPrompt: "Corrija ortografia, pontuação e capitalização do texto transcrito. Mantenha o significado original e termos técnicos em inglês. Retorne apenas o texto corrigido, sem explicações."
        ),
        CorrectionPromptTemplate(
            name: "Formalizar",
            systemPrompt: "Reescreva o texto transcrito em tom mais formal e profissional. Mantenha termos técnicos em inglês. Retorne apenas o texto reescrito, sem explicações."
        ),
        CorrectionPromptTemplate(
            name: "Resumir em bullets",
            systemPrompt: "Resuma o texto transcrito em uma lista curta de bullet points em português, destacando os pontos principais. Mantenha termos técnicos em inglês. Retorne apenas os bullets, sem introdução."
        ),
        CorrectionPromptTemplate(
            name: "Traduzir para inglês",
            systemPrompt: "Translate the transcribed text to natural, fluent English. Preserve technical terms and proper nouns. Return only the translated text, without explanations."
        )
    ]
}
