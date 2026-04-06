import SwiftUI

/// Tela de gerenciamento de prompts de correção LLM
struct CorrectionPromptsView: View {
    let appState: AppState
    @Bindable var store: CorrectionPromptStore

    @State private var promptToDelete: CorrectionPrompt?
    @State private var modelState: LLMCorrectionManager.ModelState = .notDownloaded
    @State private var isDownloading = false

    var body: some View {
        Form {
            // Toggle global
            Section {
                Toggle("Correção LLM ativa", isOn: Bindable(appState).llmCorrectionEnabled)
            }

            // Seção modelo LLM
            Section("Modelo LLM") {
                HStack {
                    Label {
                        switch modelState {
                        case .notDownloaded:
                            Text("Modelo não baixado")
                        case .downloading(let progress):
                            Text("Baixando... \(Int(progress * 100))%")
                        case .downloaded:
                            Text("Modelo baixado")
                        case .loading:
                            Text("Carregando modelo...")
                        case .ready:
                            Text("Modelo pronto")
                        case .error(let message):
                            Text("Erro: \(message)")
                                .foregroundStyle(.red)
                        }
                    } icon: {
                        Image(systemName: modelStateIcon)
                            .foregroundStyle(modelStateColor)
                    }

                    Spacer()

                    if isDownloading {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                switch modelState {
                case .notDownloaded, .error:
                    Button("Baixar Modelo") {
                        downloadModel()
                    }
                    .disabled(isDownloading)
                    .accessibilityIdentifier("downloadModelButton")

                case .downloaded:
                    Button("Carregar Modelo") {
                        loadModel()
                    }
                    .accessibilityIdentifier("loadModelButton")
                    Button("Remover Modelo", role: .destructive) {
                        removeModel()
                    }
                    .accessibilityIdentifier("removeModelButton")

                case .ready:
                    Text("Modelo pronto para uso")
                        .foregroundStyle(.green)
                    Button("Remover Modelo", role: .destructive) {
                        removeModel()
                    }

                default:
                    EmptyView()
                }
            }

            // Seção prompts
            Section("Prompts") {
                if store.prompts.isEmpty {
                    ContentUnavailableView(
                        "Nenhum prompt",
                        systemImage: "sparkles",
                        description: Text("Adicione prompts para correção pós-transcrição.")
                    )
                } else {
                    ForEach(Array(store.prompts.enumerated()), id: \.element.id) { index, prompt in
                        Section {
                            TextField("Nome", text: $store.prompts[index].name)

                            TextEditor(text: $store.prompts[index].systemPrompt)
                                .frame(minHeight: 60, maxHeight: 100)
                                .font(.body)

                            HStack {
                                Button {
                                    store.setActive(prompt)
                                } label: {
                                    Label(
                                        prompt.isActive ? "Ativo" : "Ativar",
                                        systemImage: prompt.isActive
                                            ? "checkmark.circle.fill"
                                            : "circle"
                                    )
                                    .foregroundStyle(prompt.isActive ? .green : .secondary)
                                }
                                .buttonStyle(.borderless)

                                Spacer()

                                Button("Apagar", role: .destructive) {
                                    promptToDelete = prompt
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Correção LLM")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    store.addPrompt(name: "Novo prompt", systemPrompt: "")
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
                    promptToDelete = nil
                }
            }
        } message: {
            Text("Esta ação não pode ser desfeita.")
        }
        .onChange(of: store.prompts) {
            store.save()
        }
        .task {
            modelState = await appState.llmModelState()
        }
    }

    // MARK: - Modelo

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

    private func downloadModel() {
        Task {
            isDownloading = true
            modelState = .downloading(progress: 0)
            modelState = await appState.downloadLLMModel()
            isDownloading = false
        }
    }

    private func loadModel() {
        Task {
            modelState = .loading
            modelState = await appState.loadLLMModel()
        }
    }

    private func removeModel() {
        Task {
            await appState.removeLLMModel()
            modelState = .notDownloaded
        }
    }
}
