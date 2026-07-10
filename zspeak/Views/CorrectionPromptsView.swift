import AppKit
import SwiftUI

/// Campo de busca nativo do macOS para evitar problemas de foco em `Form`.
private struct ModelSearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let isEnabled: Bool
    let onSubmit: () -> Void

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.identifier = NSUserInterfaceItemIdentifier("llmModelSearchField")
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.submit(_:))
        field.isEnabled = isEnabled
        field.isBordered = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.focusRingType = .default
        field.font = NSFont.systemFont(ofSize: 14)
        return field
    }

    func updateNSView(_ nsView: NSSearchField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onSubmit = onSubmit
        nsView.placeholderString = placeholder
        nsView.isEnabled = isEnabled
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit)
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        var onSubmit: () -> Void

        init(text: Binding<String>, onSubmit: @escaping () -> Void) {
            self.text = text
            self.onSubmit = onSubmit
        }

        @MainActor
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }

        @MainActor
        @objc func submit(_ sender: NSSearchField) {
            text.wrappedValue = sender.stringValue
            onSubmit()
        }
    }
}

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
    @State private var downloadProgress: LLMDownloadProgressSnapshot?
    @State private var downloadTask: Task<Void, Never>?
    @State private var selectedModelID = LLMModelOption.defaultID
    @State private var modelSizeOnDisk: Int64?
    @State private var cachedModels: [LLMCorrectionManager.CachedModelInfo] = []
    @State private var modelFilter = ""
    @State private var remoteModels: [LLMModelOption] = LLMModelOption.customModels()
    @State private var isSearchingRemoteModels = false
    @State private var remoteSearchError: String?
    @State private var isBusy = false
    @State private var expandedIDs: Set<UUID> = []

    @State private var autosaveToken: Int = 0

    // MARK: - Body

    var body: some View {
        Form {
            // Toggle global
            Section {
                Toggle(isOn: Bindable(appState).llmCorrectionEnabled) {
                    ZSRowLabel("Correção LLM ativa", systemImage: "sparkles", color: .purple, subtitle: "Pós-processa a transcrição com o prompt ativo")
                }
            }

            // Modelo LLM compacto
            Section("Modelo LLM") {
                modelPicker
                modelRow
                if case .downloading(let progress) = modelState {
                    downloadProgressSummary(fallbackProgress: progress)
                }
                if case .error(let message) = modelState {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }

            cachedModelsSection

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
        .zsAppSurface()
        .navigationTitle("Correção LLM")
        .navigationSubtitle("Modelo local e prompts de pós-processamento")
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
            let selected = await appState.selectedLLMModel()
            selectedModelID = selected.id
            remoteModels = LLMModelOption.customModels()
            modelState = await appState.llmModelState()
            downloadProgress = await appState.llmDownloadProgressSnapshot()
            await refreshModelMetadata()
        }
        .onChange(of: selectedModelID) { _, newValue in
            selectModel(id: newValue)
        }
    }

    // MARK: - Model row

    @ViewBuilder
    private var modelPicker: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Escolher modelo", systemImage: "sparkles")
                        .font(.headline)

                    Spacer()

                    Text("\(pickerModelOptions.count) encontrados")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    ModelSearchField(
                        text: $modelFilter,
                        placeholder: "Buscar por nome, tamanho ou quantização",
                        isEnabled: LLMModelSearchPolicy.canEditSearchText(
                            modelOperationInProgress: isBusy || isApplyingModelOperation,
                            remoteSearchInProgress: isSearchingRemoteModels
                        ),
                        onSubmit: searchRemoteModels
                    )
                    .frame(height: 36)

                    if modelFilter.isEmpty == false {
                        Button("Limpar") {
                            modelFilter = ""
                            remoteSearchError = nil
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .accessibilityLabel("Limpar busca de modelos")
                    }
                }

                Text("Digite algo como Qwen 3.6, 27B, 8-bit, OptiQ ou MLX. A lista local filtra na hora.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            modelCatalogSection

            Divider()

            remoteDiscoverySection
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: ZSDesign.radius)
                .fill(ZSDesign.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ZSDesign.radius)
                .stroke(ZSDesign.hairline, lineWidth: 0.8)
        )
        .shadow(color: ZSDesign.cardShadow, radius: 8, y: 3)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var modelCatalogSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Modelos conhecidos", systemImage: "square.stack.3d.up")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                Text("\(pickerModelOptions.count)")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            if pickerModelOptions.isEmpty {
                Text("Nenhum modelo conhecido encontrado.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(visiblePickerModelOptions) { model in
                    modelChoiceRow(model)
                }

                if pickerModelOptions.count > visiblePickerModelOptions.count {
                    Text("Mostrando os \(visiblePickerModelOptions.count) primeiros. Refine a busca para reduzir a lista.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var remoteDiscoverySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Encontrar novo", systemImage: "globe")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    searchRemoteModels()
                } label: {
                    if isSearchingRemoteModels {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Buscando")
                        }
                    } else {
                        Text("Buscar MLX")
                    }
                }
                .controlSize(.small)
                .disabled(!LLMModelSearchPolicy.canStartRemoteSearch(
                    query: modelSearchQuery,
                    modelOperationInProgress: isBusy || isApplyingModelOperation,
                    remoteSearchInProgress: isSearchingRemoteModels
                ))
            }

            if modelSearchQuery.isEmpty {
                Text("Pesquise acima e clique em Buscar MLX para encontrar modelos MLX no Hugging Face sem baixar nada automaticamente.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let remoteSearchError {
                Text(remoteSearchError)
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if remoteDiscoveryOptions.isEmpty {
                Text("Clique em Buscar no Hugging Face para procurar por \"\(modelSearchQuery)\".")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(visibleRemoteDiscoveryOptions) { model in
                    modelChoiceRow(model)
                }

                if remoteDiscoveryOptions.count > visibleRemoteDiscoveryOptions.count {
                    Text("Mostrando os \(visibleRemoteDiscoveryOptions.count) primeiros resultados remotos.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func modelChoiceRow(_ model: LLMModelOption) -> some View {
        let isSelected = model.id == selectedModelID

        return HStack(spacing: 10) {
            Button {
                selectedModelID = model.id
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? .green : .secondary)
                        .frame(width: 20)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.displayName)
                            .font(.body.weight(isSelected ? .semibold : .regular))
                            .foregroundStyle(.primary)
                        Text(model.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(isBusy || isApplyingModelOperation)

            Spacer(minLength: 8)

            modelListAction(for: model)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: ZSDesign.radius)
                .fill(isSelected ? ZSDesign.successAccent.opacity(0.13) : ZSDesign.raisedBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ZSDesign.radius)
                .strokeBorder(
                    isSelected ? ZSDesign.successAccent.opacity(0.46) : ZSDesign.hairline,
                    lineWidth: 0.7
                )
        )
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isBusy, !isApplyingModelOperation else { return }
            selectedModelID = model.id
        }
    }

    @ViewBuilder
    private func modelListAction(for model: LLMModelOption) -> some View {
        let isCached = cachedModels.contains(where: { $0.id == model.id })
        let action = LLMModelRowActionPolicy.primaryAction(
            modelID: model.id,
            selectedModelID: selectedModelID,
            selectedModelState: modelState,
            isCached: isCached
        )
        let canRemoveCachedModel = LLMModelRowActionPolicy.canRemoveCachedModel(
            modelID: model.id,
            selectedModelID: selectedModelID,
            selectedModelState: modelState,
            isCached: isCached
        )

        switch action {
        case .select:
            HStack(spacing: 6) {
                Button("Selecionar") {
                    selectedModelID = model.id
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isBusy || isApplyingModelOperation)

                if canRemoveCachedModel {
                    Button("Remover", role: .destructive) {
                        removeCachedModel(id: model.id)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isBusy || isApplyingModelOperation)
                }
            }

        case .download:
            Button("Baixar") {
                downloadModel()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(isBusy || isApplyingModelOperation)

        case .load:
            HStack(spacing: 6) {
                Button("Carregar") {
                    loadModel()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isBusy || isApplyingModelOperation)

                if canRemoveCachedModel {
                    Button("Remover", role: .destructive) {
                        removeModel()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isBusy || isApplyingModelOperation)
                }
            }

        case .retryDownload:
            HStack(spacing: 6) {
                Button("Tentar de novo") {
                    downloadModel()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isBusy || isApplyingModelOperation)

                if canRemoveCachedModel {
                    Button("Remover", role: .destructive) {
                        removeModel()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isBusy || isApplyingModelOperation)
                }
            }

        case .remove:
            Button("Remover", role: .destructive) {
                removeModel()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isBusy || isApplyingModelOperation)

        case .wait:
            HStack(spacing: 8) {
                VStack(alignment: .trailing, spacing: 2) {
                    ProgressView(value: currentDownloadProgress, total: 1)
                        .progressViewStyle(.linear)
                        .frame(width: 92)
                    Text(downloadStatusText(fallbackProgress: currentDownloadProgress))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Button("Cancelar", role: .cancel) {
                    cancelDownload()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

        case .current:
            Text("Selecionado")
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.green.opacity(0.2)))
                .foregroundStyle(.green)
        }
    }

    @ViewBuilder
    private func modelStatusBadge(for model: LLMModelOption) -> some View {
        if model.id == selectedModelID {
            Text("Selecionado")
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.green.opacity(0.2)))
                .foregroundStyle(.green)
        } else if cachedModels.contains(where: { $0.id == model.id }) {
            Text("No Mac")
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.blue.opacity(0.18)))
                .foregroundStyle(.blue)
        }
    }

    private var pickerModelOptions: [LLMModelOption] {
        LLMModelOption.filteredCatalog(matching: modelFilter)
    }

    private var visiblePickerModelOptions: [LLMModelOption] {
        LLMModelSearchLayout.visibleLocalModels(matching: modelFilter)
    }

    private var remoteDiscoveryOptions: [LLMModelOption] {
        LLMModelOption.filter(remoteModels, matching: modelFilter)
    }

    private var visibleRemoteDiscoveryOptions: [LLMModelOption] {
        Array(remoteDiscoveryOptions.prefix(LLMModelSearchLayout.remoteVisibleLimit))
    }

    private var modelSearchQuery: String {
        modelFilter.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func searchableText(for model: LLMModelOption) -> String {
        LLMModelOption.searchableText(for: model)
    }

    private func normalizedModelSearchText(_ text: String) -> String {
        LLMModelOption.normalizedSearchText(text)
    }


    @ViewBuilder
    private var modelRow: some View {
        let selectedModel = LLMModelOption.model(for: selectedModelID)
        HStack(spacing: 10) {
            ZSSettingsIcon(systemImage: "cpu.fill", color: modelStateColor, size: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(selectedModel.displayName)
                    .font(.body)
                Text(modelStateSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            modelStateBadge

            modelCTA
        }
        Text(selectedModel.note)
            .font(.caption)
            .foregroundStyle(.secondary)
        if let warning = selectedModel.usageWarning {
            Label(warning, systemImage: "tortoise.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        }
        if let modelSizeOnDisk {
            Text("Ocupando \(formattedByteSize(modelSizeOnDisk)) no cache local.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var cachedModelsSection: some View {
        if !cachedModels.isEmpty {
            Section("Cache local") {
                ForEach(cachedModels) { cached in
                    HStack(spacing: 10) {
                        Image(systemName: cached.id == selectedModelID ? "checkmark.circle.fill" : "externaldrive")
                            .foregroundStyle(cached.id == selectedModelID ? .green : .secondary)
                            .frame(width: 22)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(cached.model.displayName)
                                .font(.body)
                            Text(formattedByteSize(cached.sizeBytes))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        if cached.id == selectedModelID {
                            Text("Selecionado")
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.green.opacity(0.2)))
                                .foregroundStyle(.green)
                        } else {
                            Button("Selecionar") {
                                selectedModelID = cached.id
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(isBusy || isApplyingModelOperation)
                        }

                        Button("Remover", role: .destructive) {
                            removeCachedModel(id: cached.id)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(isBusy || isApplyingModelOperation)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard cached.id != selectedModelID else { return }
                        guard !isBusy, !isApplyingModelOperation else { return }
                        selectedModelID = cached.id
                    }
                }
            }
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
        case .notDownloaded:
            Button("Baixar") { downloadModel() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isBusy)
                .accessibilityIdentifier("downloadModelButton")

        case .error:
            HStack(spacing: 6) {
                Button("Tentar de novo") { downloadModel() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isBusy)
                    .accessibilityIdentifier("retryDownloadModelButton")
                if modelSizeOnDisk != nil {
                    Button("Remover cache", role: .destructive) { removeModel() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(isBusy)
                        .accessibilityIdentifier("removeModelButton")
                }
            }

        case .downloading(let progress):
            HStack(spacing: 8) {
                VStack(alignment: .trailing, spacing: 2) {
                    ProgressView(value: activeDownloadProgress(fallbackProgress: progress), total: 1)
                        .progressViewStyle(.linear)
                        .frame(width: 96)
                    Text(downloadStatusText(fallbackProgress: progress))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Button("Cancelar", role: .cancel) {
                    cancelDownload()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("cancelDownloadModelButton")
            }

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
        case .downloading(let progress): "Baixando \(downloadPercentText(fallbackProgress: progress))"
        case .loading: "Carregando"
        case .downloaded: "Baixado"
        case .ready: "Pronto"
        case .error: "Erro"
        }
    }

    private var modelStateSubtitle: String {
        let selectedModel = LLMModelOption.model(for: selectedModelID)
        return switch modelState {
        case .notDownloaded: "\(selectedModel.subtitle) · não baixado"
        case .downloading(let progress): "\(selectedModel.subtitle) · baixando \(downloadStatusText(fallbackProgress: progress))"
        case .loading: "Carregando na memória..."
        case .downloaded: "\(selectedModel.subtitle) · pronto para carregar"
        case .ready: "\(selectedModel.subtitle) · pronto para corrigir"
        case .error: "Falha; tente novamente"
        }
    }

    private var isApplyingModelOperation: Bool {
        switch modelState {
        case .downloading, .loading:
            return true
        default:
            return false
        }
    }

    private var currentDownloadProgress: Double {
        if case .downloading(let progress) = modelState {
            return activeDownloadProgress(fallbackProgress: progress)
        }
        return 0
    }

    @ViewBuilder
    private func downloadProgressSummary(fallbackProgress: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: activeDownloadProgress(fallbackProgress: fallbackProgress), total: 1)
                .progressViewStyle(.linear)

            HStack(spacing: 8) {
                Text("Download: \(downloadStatusText(fallbackProgress: fallbackProgress))")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Cancelar download", role: .cancel) {
                    cancelDownload()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("cancelDownloadModelButton")
            }

            if let remainingText = downloadRemainingText() {
                Text(remainingText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func activeDownloadProgress(fallbackProgress: Double) -> Double {
        downloadProgress?.fraction ?? min(max(fallbackProgress, 0), 1)
    }

    private func downloadPercentText(fallbackProgress: Double) -> String {
        LLMDownloadProgressPresentation.percentText(
            snapshot: downloadProgress,
            fallbackFraction: fallbackProgress
        )
    }

    private func downloadStatusText(fallbackProgress: Double) -> String {
        LLMDownloadProgressPresentation.statusText(
            snapshot: downloadProgress,
            fallbackFraction: fallbackProgress
        )
    }

    private func downloadRemainingText() -> String? {
        LLMDownloadProgressPresentation.remainingText(snapshot: downloadProgress)
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
                    .font(.body.weight(.medium))
                    .foregroundStyle(prompt.name.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                Spacer()
                if prompt.isActive {
                    ZSStatusChip(text: "Ativo", tone: .success, systemImage: "checkmark")
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

    private func selectModel(id: String) {
        Task {
            isBusy = true
            LLMModelOption.registerCustomModel(id: id)
            remoteModels = LLMModelOption.customModels()
            modelState = await appState.selectLLMModel(id: id)
            downloadProgress = await appState.llmDownloadProgressSnapshot()
            await refreshModelMetadata()
            isBusy = false
        }
    }

    private func searchRemoteModels() {
        Task {
            let query = modelSearchQuery
            guard query.isEmpty == false else { return }

            isSearchingRemoteModels = true
            remoteSearchError = nil

            do {
                let results = try await HuggingFaceModelSearch().search(query: query)
                remoteModels = results
                if results.isEmpty {
                    remoteSearchError = "Nenhum modelo MLX encontrado para essa busca."
                }
            } catch {
                remoteSearchError = error.localizedDescription
            }

            isSearchingRemoteModels = false
        }
    }

    private func downloadModel() {
        downloadTask?.cancel()
        downloadTask = Task { @MainActor in
            isBusy = true
            modelState = .downloading(progress: 0)
            downloadProgress = LLMDownloadProgressSnapshot(
                fraction: 0,
                completedBytes: nil,
                totalBytes: nil
            )

            let progressTask = Task { @MainActor in
                while !Task.isCancelled {
                    modelState = await appState.llmModelState()
                    downloadProgress = await appState.llmDownloadProgressSnapshot()
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
            }

            let finalState = await appState.downloadLLMModel()
            progressTask.cancel()
            if Task.isCancelled {
                await appState.cancelLLMModelDownload()
                modelState = .notDownloaded
            } else {
                modelState = finalState
            }
            downloadProgress = await appState.llmDownloadProgressSnapshot()
            await refreshModelMetadata()
            isBusy = false
            downloadTask = nil
        }
    }

    private func cancelDownload() {
        downloadTask?.cancel()
        Task { @MainActor in
            isBusy = true
            await appState.cancelLLMModelDownload()
            modelState = await appState.llmModelState()
            downloadProgress = await appState.llmDownloadProgressSnapshot()
            await refreshModelMetadata()
            isBusy = false
            downloadTask = nil
        }
    }

    private func loadModel() {
        Task {
            isBusy = true
            modelState = .loading
            modelState = await appState.loadLLMModel()
            await refreshModelMetadata()
            isBusy = false
        }
    }

    private func removeModel() {
        Task {
            isBusy = true
            await appState.removeLLMModel()
            modelState = .notDownloaded
            downloadProgress = nil
            await refreshModelMetadata()
            isBusy = false
        }
    }

    private func removeCachedModel(id: String) {
        Task {
            isBusy = true
            await appState.removeLLMModel(id: id)
            if id == selectedModelID {
                modelState = await appState.llmModelState()
                downloadProgress = await appState.llmDownloadProgressSnapshot()
            }
            await refreshModelMetadata()
            isBusy = false
        }
    }

    private func refreshModelMetadata() async {
        modelSizeOnDisk = await appState.llmModelSizeOnDisk()
        cachedModels = await appState.cachedLLMModelsOnDisk()
    }

    private func formattedByteSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
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
