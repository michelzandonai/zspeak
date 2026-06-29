import Foundation
import FluidAudio

/// Parâmetros do context biasing nativo.
///
/// Com vocabulário técnico grande, o FluidAudio já exige similaridade efetiva
/// mínima de 0.60. Mantemos esse piso explícito aqui para documentar a escolha:
/// forte o bastante para termos técnicos, sem baixar guarda contra falso positivo.
enum VocabularyBiasingProfile {
    static let alpha: Float = 0.5
    static let minCtcScore: Float = -12.0
    static let minSimilarity: Float = 0.60
    static let minCombinedConfidence: Float = 0.58
    static let minTermLength = 3
}

/// Camada de persistência para vocabulário customizado
@Observable
@MainActor
final class VocabularyStore {
    var entries: [VocabularyEntry] = []

    private let vocabularyFile: URL

    /// Fila serial dedicada a encode + I/O. Fora da main thread.
    @ObservationIgnored
    private let persistQueue: DispatchQueue

    init() {
        let base = SafePath.firstURL(for: .applicationSupportDirectory)
        let appDir = base.appendingPathComponent("zspeak", isDirectory: true)
        vocabularyFile = appDir.appendingPathComponent("vocabulary.json")
        persistQueue = StorePersistQueue.shared(forFileAt: vocabularyFile)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        entries = loadEntries()
        seedDefaultsIfNeeded(in: appDir)
    }

    /// Inicializador com DI para testes
    init(baseDirectory: URL) {
        vocabularyFile = baseDirectory.appendingPathComponent("vocabulary.json")
        persistQueue = StorePersistQueue.shared(forFileAt: vocabularyFile)
        try? FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        entries = loadEntries()
        seedDefaultsIfNeeded(in: baseDirectory)
    }

    // MARK: - API pública

    /// Adiciona uma nova entrada de vocabulário
    func addEntry(term: String, aliases: [String] = [], weight: Float = 10.0) {
        let entry = VocabularyEntry(term: term, aliases: aliases, weight: weight)
        entries.append(entry)
        saveJSON()
    }

    /// Remove uma entrada de vocabulário
    func deleteEntry(_ entry: VocabularyEntry) {
        entries.removeAll { $0.id == entry.id }
        saveJSON()
    }

    /// Constrói contexto de vocabulário para o decoder a partir das entries habilitadas
    func buildVocabularyContext() -> CustomVocabularyContext {
        let terms = entries.filter(\.isEnabled).map { entry in
            CustomVocabularyTerm(
                text: entry.term,
                weight: entry.weight,
                aliases: entry.aliases.isEmpty ? nil : entry.aliases
            )
        }
        return CustomVocabularyContext(
            terms: terms,
            alpha: VocabularyBiasingProfile.alpha,
            minCtcScore: VocabularyBiasingProfile.minCtcScore,
            minSimilarity: VocabularyBiasingProfile.minSimilarity,
            minCombinedConfidence: VocabularyBiasingProfile.minCombinedConfidence,
            minTermLength: VocabularyBiasingProfile.minTermLength
        )
    }

    /// Aplica substituições aliases → term no texto transcrito.
    ///
    /// Fallback em Swift para complementar o context biasing nativo do FluidAudio.
    /// Serve como rede de segurança para aliases exatos no texto final.
    ///
    /// - Busca com word boundaries (`\b`) — não substitui dentro de palavras
    /// - Case-insensitive — "Git Pool", "git pool", "GIT POOL" todos viram o term
    /// - Preserva o casing do term cadastrado pelo usuário
    /// - Aliases mais longos são aplicados primeiro, evitando que um alias curto "vaze"
    ///   dentro de um alias mais longo que ainda não foi processado
    /// - Apenas entradas habilitadas (`isEnabled`) participam
    func applyReplacements(to text: String) -> String {
        guard !text.isEmpty else { return text }

        var pairs: [(alias: String, term: String)] = []
        for entry in entries where entry.isEnabled {
            let term = entry.term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty else { continue }
            for alias in entry.aliases {
                let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                pairs.append((alias: trimmed, term: term))
            }
        }
        pairs.sort { $0.alias.count > $1.alias.count }

        guard !pairs.isEmpty else { return text }

        var result = text
        for (alias, term) in pairs {
            let escapedAlias = NSRegularExpression.escapedPattern(for: alias)
            let pattern = "\\b\(escapedAlias)\\b"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            let range = NSRange(location: 0, length: (result as NSString).length)
            result = regex.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: NSRegularExpression.escapedTemplate(for: term)
            )
        }
        return result
    }

    // MARK: - Persistência JSON

    /// Persiste entries no disco (chamado após edições inline na view)
    func save() {
        saveJSON()
    }

    /// Envelope versionado: `{ schemaVersion: 1, entries: [...] }`.
    fileprivate struct Envelope: Codable {
        let schemaVersion: Int
        let entries: [VocabularyEntry]
    }

    /// Captura snapshot no main e enfileira encode+write no background.
    private func saveJSON() {
        let snapshot = entries
        let file = vocabularyFile
        persistQueue.async {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

            let envelope = Envelope(
                schemaVersion: VocabularyStoreSchema.currentVersion,
                entries: snapshot
            )

            guard let data = try? encoder.encode(envelope) else { return }
            try? data.write(to: file, options: .atomic)
        }
    }

    private func loadEntries() -> [VocabularyEntry] {
        // Drena writes pendentes antes de reler (testes em mesmo diretório).
        persistQueue.sync { }

        guard FileManager.default.fileExists(atPath: vocabularyFile.path) else {
            return []
        }

        let data: Data
        do {
            data = try Data(contentsOf: vocabularyFile)
        } catch {
            StoreLog.shared.log("VocabularyStore: falha ao ler \(vocabularyFile.lastPathComponent): \(error)")
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // Formato novo (envelope).
        if let envelope = try? decoder.decode(Envelope.self, from: data) {
            if envelope.schemaVersion == VocabularyStoreSchema.currentVersion {
                return envelope.entries
            }
            StoreLog.shared.log("VocabularyStore: schemaVersion desconhecida \(envelope.schemaVersion); fazendo backup e começando vazio")
            StoreLog.shared.backup(fileURL: vocabularyFile)
            return []
        }

        // Formato legado (array direto) — migra para v1.
        if let legacy = try? decoder.decode([VocabularyEntry].self, from: data) {
            return legacy
        }

        StoreLog.shared.log("VocabularyStore: JSON malformado em \(vocabularyFile.lastPathComponent); fazendo backup")
        StoreLog.shared.backup(fileURL: vocabularyFile)
        return []
    }

    // MARK: - Defaults

    /// Entradas padrão da v1 — já existentes em instalações antigas.
    /// Controladas por uma flag própria para não ressuscitar termos deletados.
    private static let defaultEntriesV1: [(term: String, aliases: [String], weight: Float)] = [
        ("Claude Code", ["cloud code"], 10.0),
        ("git pull", ["git pool"], 10.0)
    ]

    /// Entradas padrão adicionadas em upgrades posteriores.
    /// Mantidas em batch separado para que instalações antigas recebam só os
    /// novos termos, sem reintroduzir defaults v1 removidos manualmente.
    private static let defaultEntriesV2: [(term: String, aliases: [String], weight: Float)] = [
        ("branch", [], 15.0),
        ("branches", [], 15.0)
    ]

    /// Primeiro pacote derivado da conversa real do usuário + PRD:
    /// comandos Git, stack Swift/macOS e termos do pipeline local de ASR/LLM.
    private static let defaultEntriesV3: [(term: String, aliases: [String], weight: Float)] = [
        ("main", [], 8.0),
        ("GitHub", ["git hub"], 12.0),
        ("git fetch", ["get fetch"], 12.0),
        ("git status", ["get status"], 12.0),
        ("git diff", ["get diff"], 12.0),
        ("git stash", ["get stash"], 12.0),
        ("git push", ["get push"], 12.0),
        ("git merge", ["get merge"], 12.0),
        ("git rebase", ["get rebase"], 12.0),
        ("git checkout", ["get checkout"], 12.0),
        ("origin/main", ["origin main"], 10.0),
        ("pull request", ["pool request"], 12.0),
        ("commit", [], 10.0),
        ("merge", [], 10.0),
        ("deploy", [], 10.0),
        ("API", ["a p i"], 12.0),
        ("endpoint", ["end point"], 10.0),
        ("TypeScript", ["type script"], 12.0),
        ("Docker", [], 10.0),
        ("Kubernetes", ["cubernetes"], 12.0),
        ("CI/CD", ["ci cd", "c i c d"], 12.0),
        ("Xcode", ["x code", "ex code"], 12.0),
        ("xcodebuild", ["x code build", "ex code build"], 12.0),
        ("Swift", [], 10.0),
        ("SwiftUI", ["swift ui", "swift u i"], 12.0),
        ("Swift Package Manager", [], 10.0),
        ("SPM", ["s p m"], 10.0),
        ("CoreML", ["core ml", "core m l"], 12.0),
        ("MLX", ["m l x"], 12.0),
        ("LLM", ["l l m"], 12.0),
        ("FluidAudio", ["fluid audio"], 12.0),
        ("AVAudioEngine", ["a v audio engine", "av audio engine"], 12.0),
        ("CGEvent", ["c g event"], 12.0),
        ("NSPasteboard", ["n s pasteboard"], 12.0),
        ("KeyboardShortcuts", ["keyboard shortcuts", "keyboard shortcut"], 10.0),
        ("LaunchAtLogin", ["launch at login"], 10.0),
        ("Parakeet TDT", ["parakeet tdt"], 12.0),
        ("Silero VAD", ["silero vad"], 12.0),
        ("HuggingFace", ["hugging face"], 10.0),
        ("Apple Silicon", [], 10.0),
        ("Apple Neural Engine", [], 10.0),
        ("ANE", ["a n e"], 10.0),
        ("macOS", ["mac os"], 10.0),
        ("MenuBarExtra", ["menu bar extra"], 10.0),
        ("UserDefaults", ["user defaults"], 10.0),
        ("snapshot", [], 8.0),
        ("snapshots", [], 8.0)
    ]

    /// Aliases novos para termos de batches antigos. Separado para não reintroduzir
    /// termos que o usuário deletou manualmente em instalações existentes.
    private static let defaultAliasUpdatesV3: [(term: String, aliases: [String])] = [
        ("git pull", ["gitpool", "get pull", "get pool"])
    ]

    /// Segundo pacote derivado de revisão/build/release do projeto.
    /// Mantido em batch separado para instalações que já semearam a v3.
    private static let defaultEntriesV4: [(term: String, aliases: [String], weight: Float)] = [
        ("Codex", ["códex"], 12.0),
        ("ChatGPT", ["chat gpt", "chat g p t"], 12.0),
        ("OpenAI", ["open ai", "open a i"], 10.0),
        ("git add", ["get add"], 12.0),
        ("git log", ["get log"], 12.0),
        ("git show", ["get show"], 12.0),
        ("git reset", ["get reset"], 10.0),
        ("git clone", ["get clone"], 10.0),
        ("git clean", ["get clean"], 10.0),
        ("fast-forward", ["fast forward"], 10.0),
        ("ff-only", ["ff only", "f f only"], 10.0),
        ("HEAD", ["head"], 8.0),
        ("remote", [], 8.0),
        ("upstream", [], 8.0),
        ("staged", [], 10.0),
        ("unstaged", ["un staged"], 10.0),
        ("untracked", ["un tracked"], 10.0),
        ("stash@{0}", ["stash zero"], 8.0),
        ("merge conflict", ["conflito de merge"], 10.0),
        ("workspace", ["work space"], 8.0),
        ("worktree", ["work tree"], 8.0),
        ("scheme", [], 8.0),
        ("Debug", [], 8.0),
        ("destination", [], 8.0),
        ("XCTest", ["x c test"], 10.0),
        ("Swift Testing", [], 10.0),
        ("Package.swift", ["package swift"], 10.0),
        ("Package.resolved", ["package resolved"], 10.0),
        ("DerivedData", ["derived data"], 10.0),
        ("Info.plist", ["info plist"], 10.0),
        ("entitlements", [], 8.0),
        ("DMG", ["d m g"], 10.0),
        ("ffmpeg", ["f f mpeg", "efe efe mpeg"], 10.0),
        ("OPUS", ["opus"], 8.0),
        ("M4A", ["m quatro a", "m 4 a"], 8.0),
        ("WAV", ["wave", "uav"], 8.0),
        ("pyannote", ["pai anote", "py anote"], 10.0),
        ("WeSpeaker", ["we speaker"], 10.0),
        ("diarização", ["diarization"], 8.0),
        ("speaker", [], 8.0),
        ("speakers", [], 8.0),
        ("ASR", ["a s r"], 12.0),
        ("VAD", ["v a d"], 12.0),
        ("VADManager", ["vad manager", "v a d manager"], 10.0),
        ("Prompt Mode", ["pront mode", "mode prompt"], 10.0),
        ("Modo Prompt", ["modo pront"], 10.0),
        ("prompt", ["pront"], 8.0),
        ("prompts", ["pronts"], 8.0),
        ("benchmark", ["branchmark"], 10.0),
        ("benchmarks", ["branchmarks"], 10.0),
        ("overlay", [], 10.0),
        ("hotkey", ["hot key"], 10.0),
        ("push-to-talk", ["push to talk"], 10.0),
        ("clipboard", ["clip board"], 10.0),
        ("paste", [], 8.0),
        ("Cmd+V", ["command v", "comando v"], 10.0),
        ("Accessibility", ["acessibility"], 10.0),
        ("Microphone", [], 8.0),
        ("System Settings", [], 8.0),
        ("Privacy & Security", ["privacy security"], 8.0),
        ("sandbox", [], 8.0),
        ("Keychain", ["key chain"], 8.0),
        ("Developer ID", [], 8.0),
        ("notarização", ["notarization"], 8.0)
    ]

    /// Terceiro pacote técnico focado em tuning/benchmark de assertividade.
    private static let defaultEntriesV5: [(term: String, aliases: [String], weight: Float)] = [
        ("context biasing", ["context bias"], 10.0),
        ("rescoring", ["rescore"], 10.0),
        ("decoder", [], 8.0),
        ("encoder", [], 8.0),
        ("token", [], 8.0),
        ("tokens", [], 8.0),
        ("temperature", [], 8.0),
        ("topP", ["top p"], 8.0),
        ("KV cache", ["k v cache"], 8.0),
        ("RTFx", ["r t f x"], 8.0),
        ("WER", ["w e r"], 8.0),
        ("CER", ["c e r"], 8.0),
        ("latência", ["latency"], 8.0),
        ("assertividade", [], 8.0)
    ]

    /// Semeia entradas padrão na primeira inicialização (nova instalação ou upgrade).
    /// Cada batch usa sua própria flag para permitir upgrades incrementais sem
    /// ressuscitar defaults antigos removidos pelo usuário.
    private func seedDefaultsIfNeeded(in directory: URL) {
        seedDefaults(
            Self.defaultEntriesV1,
            flagName: ".vocab_defaults_seeded",
            in: directory
        )
        seedDefaults(
            Self.defaultEntriesV2,
            flagName: ".vocab_defaults_seeded_v2",
            in: directory
        )
        seedDefaults(
            Self.defaultEntriesV3,
            flagName: ".vocab_defaults_seeded_v3",
            in: directory
        )
        seedAliasUpdates(
            Self.defaultAliasUpdatesV3,
            flagName: ".vocab_aliases_seeded_v3",
            in: directory
        )
        seedDefaults(
            Self.defaultEntriesV4,
            flagName: ".vocab_defaults_seeded_v4",
            in: directory
        )
        seedDefaults(
            Self.defaultEntriesV5,
            flagName: ".vocab_defaults_seeded_v5",
            in: directory
        )
    }

    private func seedDefaults(
        _ defaults: [(term: String, aliases: [String], weight: Float)],
        flagName: String,
        in directory: URL
    ) {
        let flagURL = directory.appendingPathComponent(flagName)
        guard !FileManager.default.fileExists(atPath: flagURL.path) else { return }

        var mutated = false
        for def in defaults {
            let alreadyExists = entries.contains {
                $0.term.caseInsensitiveCompare(def.term) == .orderedSame
            }
            if !alreadyExists {
                entries.append(VocabularyEntry(term: def.term, aliases: def.aliases, weight: def.weight))
                mutated = true
            }
        }

        if mutated {
            saveJSON()
        }
        try? Data().write(to: flagURL)
    }

    private func seedAliasUpdates(
        _ updates: [(term: String, aliases: [String])],
        flagName: String,
        in directory: URL
    ) {
        let flagURL = directory.appendingPathComponent(flagName)
        guard !FileManager.default.fileExists(atPath: flagURL.path) else { return }

        var mutated = false
        for update in updates {
            guard let entryIndex = entries.firstIndex(where: {
                $0.term.caseInsensitiveCompare(update.term) == .orderedSame
            }) else {
                continue
            }

            for alias in update.aliases {
                let alreadyExists = entries[entryIndex].aliases.contains {
                    $0.caseInsensitiveCompare(alias) == .orderedSame
                }
                if !alreadyExists {
                    entries[entryIndex].aliases.append(alias)
                    mutated = true
                }
            }
        }

        if mutated {
            saveJSON()
        }
        try? Data().write(to: flagURL)
    }
}

// MARK: - Constants / schema

/// Versão corrente do schema persistido de `VocabularyStore`.
enum VocabularyStoreSchema {
    static let currentVersion = 1
}
