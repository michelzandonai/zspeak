import Foundation

/// Modelos locais disponiveis para correcao pos-transcricao.
///
/// A lista separa o identificador real do HuggingFace do texto mostrado na UI,
/// para permitir trocar o modelo sem espalhar strings pelo app.
struct LLMModelOption: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let displayName: String
    let shortName: String
    let sizeLabel: String
    let qualityLabel: String
    let note: String
    let benchmarkOrder: Int

    var subtitle: String {
        "\(qualityLabel) · \(sizeLabel)"
    }

    var isLargeExperimentalModel: Bool {
        id.contains("Qwen3.6")
            || id.contains("DeepSeek-V4")
            || id.contains("MiMo-7B-RL")
            || id.contains("DeepSeek-R1-Distill")
    }

    var usageWarning: String? {
        if id == "mlx-community/Qwen3.5-9B-OptiQ-4bit" {
            return "Modelo de alta qualidade: use com saida curta e guardrail ativo para manter o modo sem raciocinio."
        }
        if id.contains("MiMo-7B-RL") || id.contains("DeepSeek-R1-Distill") {
            return "Modelo focado em raciocinio: maior risco de vazar etapas, <think> ou resposta de assistente. Use apenas para teste manual."
        }
        if isLargeExperimentalModel {
            return "Modelo pesado ou experimental: pode baixar muitos GB e nao e recomendado para uso diario no zspeak."
        }
        return nil
    }

    static let defaultID = "Qwen/Qwen3-8B-MLX-4bit"
    private static let customModelIDsDefaultsKey = "customLLMModelIDs"
    private static let retiredBuiltInModelIDs: Set<String> = [
        "mlx-community/Qwen3.5-2B-OptiQ-4bit",
        "mlx-community/Qwen2.5-3B-Instruct-4bit",
        "mlx-community/Qwen3-4B-Instruct-2507-4bit",
        "mlx-community/Qwen2.5-7B-Instruct-4bit",
        "Qwen/Qwen3-14B-MLX-4bit",
        "mlx-community/Qwen2.5-14B-Instruct-4bit",
        "mlx-community/Qwen3.6-27B-OptiQ-4bit",
        "mlx-community/Qwen3.6-27B-4bit",
        "mlx-community/Qwen3.6-27B-mxfp4",
        "mlx-community/Qwen3.6-27B-nvfp4",
        "mlx-community/Qwen3.6-27B-5bit",
        "mlx-community/Qwen3.6-27B-6bit",
        "mlx-community/Qwen3.6-27B-8bit",
    ]

    static let all: [LLMModelOption] = [
        LLMModelOption(
            id: defaultID,
            displayName: "Qwen 3 8B MLX 4-bit",
            shortName: "Qwen 8B",
            sizeLabel: "~4.35 GB",
            qualityLabel: "Padrao seguro",
            note: "Conversao MLX oficial da Qwen; melhor equilibrio para PT-BR com termos tecnicos em ingles.",
            benchmarkOrder: 10
        ),
        LLMModelOption(
            id: "mlx-community/Phi-4-mini-instruct-4bit",
            displayName: "Phi-4 mini Instruct 4-bit",
            shortName: "Phi mini",
            sizeLabel: "~2.16 GB",
            qualityLabel: "Leve",
            note: "Opcao rapida e pequena; boa para correcoes simples com menor uso de disco.",
            benchmarkOrder: 20
        ),
        LLMModelOption(
            id: "mlx-community/Qwen3.5-9B-OptiQ-4bit",
            displayName: "Qwen 3.5 9B OptiQ 4-bit",
            shortName: "Qwen 9B",
            sizeLabel: "~7.1 GB",
            qualityLabel: "Alta qualidade",
            note: "OptiQ para Apple Silicon; candidato mais forte quando a prioridade for qualidade textual.",
            benchmarkOrder: 30
        ),
    ]

    static var defaultModel: LLMModelOption {
        model(for: defaultID)
    }

    static func initialModelID(storedID rawStoredID: String?) -> String {
        guard let rawStoredID else { return defaultID }

        let storedID = rawStoredID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard storedID.isEmpty == false else { return defaultID }
        guard retiredBuiltInModelIDs.contains(storedID) == false else { return defaultID }

        return storedID
    }

    static var benchmarkCandidates: [LLMModelOption] {
        let defaultBenchmarkIDs = Set([
            defaultID,
            "mlx-community/Phi-4-mini-instruct-4bit",
            "mlx-community/Qwen3.5-9B-OptiQ-4bit",
        ])
        return all
            .filter { defaultBenchmarkIDs.contains($0.id) }
            .sorted { $0.benchmarkOrder < $1.benchmarkOrder }
    }

    static var allBenchmarkCandidates: [LLMModelOption] {
        all.sorted { $0.benchmarkOrder < $1.benchmarkOrder }
    }

    static func catalog(userDefaults: UserDefaults = .standard) -> [LLMModelOption] {
        uniqueModels(all + customModels(userDefaults: userDefaults))
            .sorted { lhs, rhs in
                if lhs.benchmarkOrder == rhs.benchmarkOrder {
                    return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
                }
                return lhs.benchmarkOrder < rhs.benchmarkOrder
            }
    }

    static func customModels(userDefaults: UserDefaults = .standard) -> [LLMModelOption] {
        customModelIDs(userDefaults: userDefaults)
            .enumerated()
            .map { index, id in
                customModel(id: id, order: 10_000 + index)
            }
    }

    static func registerCustomModel(id rawID: String, userDefaults: UserDefaults = .standard) {
        let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard looksLikeRemoteModelID(id) else { return }
        guard all.contains(where: { $0.id == id }) == false else { return }

        var ids = customModelIDs(userDefaults: userDefaults)
        guard ids.contains(id) == false else { return }
        ids.append(id)
        userDefaults.set(ids, forKey: customModelIDsDefaultsKey)
    }

    static func removeCustomModel(id rawID: String, userDefaults: UserDefaults = .standard) {
        let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        let ids = customModelIDs(userDefaults: userDefaults).filter { $0 != id }
        userDefaults.set(ids, forKey: customModelIDsDefaultsKey)
    }

    static func model(for rawID: String, userDefaults: UserDefaults = .standard) -> LLMModelOption {
        let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        if let known = catalog(userDefaults: userDefaults).first(where: { $0.id == id }) {
            return known
        }
        if looksLikeRemoteModelID(id) {
            return customModel(id: id, order: 10_000)
        }
        return defaultModelFallback
    }

    static func customModel(id rawID: String, order: Int = 10_000) -> LLMModelOption {
        let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = inferredDisplayName(from: id)
        return LLMModelOption(
            id: id,
            displayName: displayName,
            shortName: inferredShortName(from: displayName),
            sizeLabel: "Tamanho remoto",
            qualityLabel: inferredQualityLabel(from: displayName),
            note: "Modelo MLX encontrado no Hugging Face. O tamanho real aparece depois do download.",
            benchmarkOrder: order
        )
    }

    static func filteredCatalog(
        matching rawQuery: String,
        userDefaults: UserDefaults = .standard
    ) -> [LLMModelOption] {
        filter(catalog(userDefaults: userDefaults), matching: rawQuery)
    }

    static func filter(_ models: [LLMModelOption], matching rawQuery: String) -> [LLMModelOption] {
        let query = normalizedSearchText(rawQuery)
        guard query.isEmpty == false else { return models }

        return models.filter { model in
            normalizedSearchText(searchableText(for: model)).contains(query)
        }
    }

    static func searchableText(for model: LLMModelOption) -> String {
        [
            model.id,
            model.displayName,
            model.shortName,
            model.qualityLabel,
            model.sizeLabel,
            model.note,
        ].joined(separator: " ")
    }

    static func normalizedSearchText(_ text: String) -> String {
        HuggingFaceModelSearch.normalizedQuery(text)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }

    private static let defaultModelFallback = LLMModelOption(
        id: defaultID,
        displayName: "Qwen 3 8B MLX 4-bit",
        shortName: "Qwen 8B",
        sizeLabel: "~4.35 GB",
        qualityLabel: "Padrao seguro",
        note: "Conversao MLX oficial da Qwen; melhor equilibrio para PT-BR com termos tecnicos em ingles.",
        benchmarkOrder: 10
    )

    private static func customModelIDs(userDefaults: UserDefaults) -> [String] {
        userDefaults.stringArray(forKey: customModelIDsDefaultsKey) ?? []
    }

    private static func uniqueModels(_ models: [LLMModelOption]) -> [LLMModelOption] {
        var seen = Set<String>()
        return models.filter { model in
            seen.insert(model.id).inserted
        }
    }

    private static func looksLikeRemoteModelID(_ id: String) -> Bool {
        id.contains("/")
            && id.contains(" ") == false
            && id.contains("\n") == false
            && id.split(separator: "/").count == 2
    }

    private static func inferredDisplayName(from id: String) -> String {
        let repo = id.split(separator: "/").last.map(String.init) ?? id
        return repo
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
    }

    private static func inferredShortName(from displayName: String) -> String {
        let pattern = #"(?i)(\d+(?:\.\d+)?B)"#
        if let range = displayName.range(of: pattern, options: .regularExpression) {
            return String(displayName[range])
        }
        return "Remoto"
    }

    private static func inferredQualityLabel(from displayName: String) -> String {
        let lowercased = displayName.lowercased()
        if lowercased.contains("27b") || lowercased.contains("32b") {
            return "Pesado"
        }
        if lowercased.contains("14b") || lowercased.contains("9b") || lowercased.contains("8b") {
            return "Intermediario"
        }
        if lowercased.contains("4bit") || lowercased.contains("mlx") || lowercased.contains("optiq") {
            return "MLX remoto"
        }
        return "Remoto"
    }
}

/// Busca modelos MLX no Hugging Face sem baixar arquivos pesados.
///
/// A busca fica restrita a candidatos com sinal claro de MLX no ID, tags ou
/// metadados do modelo. O download continua sendo feito pelo fluxo normal da UI.
struct HuggingFaceModelSearch {
    var limit: Int = 50

    func search(query rawQuery: String) async throws -> [LLMModelOption] {
        let query = Self.normalizedQuery(rawQuery)
        guard query.isEmpty == false else { return [] }

        var components = URLComponents(string: "https://huggingface.co/api/models")
        components?.queryItems = [
            URLQueryItem(name: "search", value: query),
            URLQueryItem(name: "sort", value: "downloads"),
            URLQueryItem(name: "direction", value: "-1"),
            URLQueryItem(name: "limit", value: String(limit)),
        ]

        guard let url = components?.url else {
            throw HuggingFaceModelSearchError.invalidURL
        }

        let (data, response) = try await URLSession.shared.data(from: url)
        if let httpResponse = response as? HTTPURLResponse,
           (200..<300).contains(httpResponse.statusCode) == false {
            throw HuggingFaceModelSearchError.badStatus(httpResponse.statusCode)
        }

        let summaries = try JSONDecoder().decode([HuggingFaceModelSummary].self, from: data)
        var seen = Set<String>()

        return summaries
            .filter(Self.isLikelyMLXModel)
            .filter { seen.insert($0.id).inserted }
            .enumerated()
            .map { index, summary in
                let base = LLMModelOption.customModel(id: summary.id, order: 10_000 + index)
                return LLMModelOption(
                    id: base.id,
                    displayName: base.displayName,
                    shortName: base.shortName,
                    sizeLabel: base.sizeLabel,
                    qualityLabel: base.qualityLabel,
                    note: Self.note(for: summary),
                    benchmarkOrder: base.benchmarkOrder
                )
            }
    }

    static func normalizedQuery(_ rawQuery: String) -> String {
        rawQuery
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "Queen", with: "Qwen", options: [.caseInsensitive])
    }

    private static func isLikelyMLXModel(_ summary: HuggingFaceModelSummary) -> Bool {
        let searchableParts = [summary.id, summary.libraryName, summary.pipelineTag]
            + summary.tags
        return searchableParts
            .compactMap { $0 }
            .joined(separator: " ")
            .localizedCaseInsensitiveContains("mlx")
    }

    private static func note(for summary: HuggingFaceModelSummary) -> String {
        var parts = ["Resultado remoto do Hugging Face filtrado para MLX."]
        if let downloads = summary.downloads {
            parts.append("\(downloads) downloads.")
        }
        parts.append("Selecione e clique em Baixar para trazer para o cache local.")
        return parts.joined(separator: " ")
    }
}

private struct HuggingFaceModelSummary: Decodable {
    let id: String
    let tags: [String]
    let downloads: Int?
    let pipelineTag: String?
    let libraryName: String?

    enum CodingKeys: String, CodingKey {
        case id
        case modelID = "modelId"
        case tags
        case downloads
        case pipelineTag = "pipeline_tag"
        case libraryName = "library_name"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedID = try container.decodeIfPresent(String.self, forKey: .id)
            ?? container.decodeIfPresent(String.self, forKey: .modelID)

        guard let decodedID else {
            throw DecodingError.keyNotFound(
                CodingKeys.id,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Modelo sem id")
            )
        }

        id = decodedID
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        downloads = try container.decodeIfPresent(Int.self, forKey: .downloads)
        pipelineTag = try container.decodeIfPresent(String.self, forKey: .pipelineTag)
        libraryName = try container.decodeIfPresent(String.self, forKey: .libraryName)
    }
}

enum HuggingFaceModelSearchError: LocalizedError {
    case invalidURL
    case badStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "Busca invalida no Hugging Face."
        case .badStatus(let status):
            "Hugging Face retornou HTTP \(status)."
        }
    }
}

struct LLMModelSearchPolicy {
    static func canEditSearchText(
        modelOperationInProgress: Bool,
        remoteSearchInProgress: Bool
    ) -> Bool {
        true
    }

    static func canStartRemoteSearch(
        query: String,
        modelOperationInProgress: Bool,
        remoteSearchInProgress: Bool
    ) -> Bool {
        remoteSearchInProgress == false
            && query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
}

struct LLMModelSearchLayout {
    static let localVisibleLimit = 12
    static let remoteVisibleLimit = 8

    static func visibleLocalModels(
        matching query: String,
        userDefaults: UserDefaults = .standard
    ) -> [LLMModelOption] {
        Array(
            LLMModelOption
                .filteredCatalog(matching: query, userDefaults: userDefaults)
                .prefix(localVisibleLimit)
        )
    }
}

struct LLMDownloadProgressSnapshot: Equatable, Sendable {
    let fraction: Double
    let completedBytes: Int64?
    let totalBytes: Int64?

    init(fraction: Double, completedBytes: Int64?, totalBytes: Int64?) {
        let safeCompletedBytes = completedBytes.flatMap { $0 >= 0 ? $0 : nil }
        let safeTotalBytes = totalBytes.flatMap { $0 > 0 ? $0 : nil }

        self.completedBytes = safeCompletedBytes
        self.totalBytes = safeTotalBytes

        let computedFraction: Double
        if fraction.isFinite {
            computedFraction = fraction
        } else if let safeCompletedBytes, let safeTotalBytes {
            computedFraction = Double(safeCompletedBytes) / Double(safeTotalBytes)
        } else {
            computedFraction = 0
        }

        self.fraction = min(max(computedFraction, 0), 1)
    }

    var percentValue: Int {
        Int((fraction * 100).rounded())
    }

    var remainingBytes: Int64? {
        guard let completedBytes, let totalBytes, totalBytes >= completedBytes else {
            return nil
        }
        return totalBytes - completedBytes
    }
}

struct LLMDownloadProgressPresentation {
    static func percentText(
        snapshot: LLMDownloadProgressSnapshot?,
        fallbackFraction: Double
    ) -> String {
        let fraction = snapshot?.fraction ?? min(max(fallbackFraction, 0), 1)
        return "\(Int((fraction * 100).rounded()))%"
    }

    static func statusText(
        snapshot: LLMDownloadProgressSnapshot?,
        fallbackFraction: Double
    ) -> String {
        let percent = percentText(snapshot: snapshot, fallbackFraction: fallbackFraction)
        guard let snapshot,
              let completedBytes = snapshot.completedBytes,
              let totalBytes = snapshot.totalBytes
        else {
            return percent
        }

        return "\(percent) · \(byteText(completedBytes)) de \(byteText(totalBytes))"
    }

    static func remainingText(snapshot: LLMDownloadProgressSnapshot?) -> String? {
        guard let remainingBytes = snapshot?.remainingBytes else { return nil }
        return "Faltam \(byteText(remainingBytes))"
    }

    private static func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

enum LLMModelRowPrimaryAction: Equatable {
    case select
    case download
    case load
    case retryDownload
    case remove
    case wait
    case current
}

struct LLMModelRowActionPolicy {
    static func primaryAction(
        modelID: String,
        selectedModelID: String,
        selectedModelState: LLMCorrectionManager.ModelState,
        isCached: Bool
    ) -> LLMModelRowPrimaryAction {
        guard modelID == selectedModelID else {
            return .select
        }

        switch selectedModelState {
        case .notDownloaded:
            return .download
        case .downloaded:
            return .load
        case .ready:
            return .remove
        case .error:
            return isCached ? .retryDownload : .download
        case .downloading, .loading:
            return .wait
        }
    }

    static func canRemoveCachedModel(
        modelID: String,
        selectedModelID: String,
        selectedModelState: LLMCorrectionManager.ModelState,
        isCached: Bool
    ) -> Bool {
        guard isCached else { return false }
        guard modelID == selectedModelID else { return true }

        switch selectedModelState {
        case .downloading, .loading:
            return false
        case .notDownloaded, .downloaded, .ready, .error:
            return true
        }
    }
}
