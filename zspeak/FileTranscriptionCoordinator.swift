import Foundation

/// Coordena o pipeline de transcrição de arquivos de áudio.
///
/// Responsabilidades:
/// - Instanciar `AudioFileTranscriber` com o closure de transcrição injetado
/// - Aplicar vocabulário customizado (substituições alias → term)
/// - Persistir o resultado no histórico (via hook)
/// - Copiar o texto final para o clipboard
/// - Expor `updateSpeakerNames` para o modo Reunião (renomeação de speakers)
///
/// NÃO segura referências a stores / managers — esses passam via hooks injetados
/// pelo `AppState`. Isso evita acoplamento e permite testes com fakes.
@MainActor
final class FileTranscriptionCoordinator {

    /// Fornece o closure de transcrição para o `AudioFileTranscriber`.
    /// Tipicamente é o método `transcribe(_:)` do `RecordingController`.
    private let transcribe: @MainActor ([Float]) async throws -> String

    /// Manager de diarização — necessário apenas para modo `.meeting`.
    var diarizationManager: DiarizationManager?

    /// Aplica substituições de vocabulário no texto final.
    var applyVocabularyReplacements: (@MainActor (String) -> String)?

    /// Persiste o record completo no histórico (opcionalmente com samples).
    /// Retorna o UUID do record criado, ou nil se o store não foi configurado.
    var persistTranscription: (@MainActor (_ text: String, _ modelName: String, _ duration: Double, _ targetAppName: String?, _ samples: [Float]?) -> UUID?)?

    /// Atualiza o map speakerID → nome em um record existente.
    var updateSpeakerNamesInStore: (@MainActor (_ recordID: UUID, _ names: [String: String]) -> Void)?

    /// Copia o texto final para o clipboard.
    private let textInserter: any TextInserting

    init(
        transcribe: @escaping @MainActor ([Float]) async throws -> String,
        textInserter: any TextInserting
    ) {
        self.transcribe = transcribe
        self.textInserter = textInserter
    }

    /// Resultado adicional exposto para o `AppState` sincronizar `lastTranscription`
    /// e `lastTranscriptionRecordID` do `LLMCoordinator` após transcrição de arquivo.
    struct FileTranscriptionOutcome {
        let result: FileTranscriptionResult
        let recordID: UUID?
    }

    /// Transcreve um arquivo de áudio (qualquer formato suportado).
    /// - Suporta modo `.plain` (texto corrido) e `.meeting` (com identificação de interlocutores)
    /// - Salva automaticamente no histórico via `persistTranscription` hook
    /// - Copia o texto final para o clipboard
    func transcribeFile(
        url: URL,
        mode: AudioFileTranscriber.Mode,
        numSpeakers: Int? = nil,
        onProgress: @escaping @MainActor (FileTranscriptionPhase) -> Void
    ) async throws -> FileTranscriptionOutcome {
        let fileTranscriber = AudioFileTranscriber(
            transcribe: { [transcribe] samples in
                try await transcribe(samples)
            },
            diarizer: diarizationManager
        )

        let rawResult = try await fileTranscriber.transcribe(
            url: url,
            mode: mode,
            numSpeakers: numSpeakers,
            onProgress: onProgress
        )

        // Aplica vocabulário customizado (substituições alias → term) no texto final
        let correctedText = applyVocabularyReplacements?(rawResult.text) ?? rawResult.text
        let result = FileTranscriptionResult(
            text: correctedText,
            segments: rawResult.segments,
            sourceFileName: rawResult.sourceFileName,
            durationSeconds: rawResult.durationSeconds,
            samples: rawResult.samples
        )

        let modelName: String = {
            switch mode {
            case .plain: return "Parakeet TDT (arquivo)"
            case .meeting: return "Parakeet TDT + Diarizer"
            }
        }()

        let newID = persistTranscription?(
            result.text,
            modelName,
            result.durationSeconds,
            nil,
            result.samples
        )

        // Copia para o clipboard
        textInserter.copyToClipboard(result.text)

        return FileTranscriptionOutcome(result: result, recordID: newID)
    }

    /// Atualiza o map de nomes de speakers de um registro de transcrição (modo Reunião).
    func updateSpeakerNames(recordID: UUID, names: [String: String]) {
        updateSpeakerNamesInStore?(recordID, names)
    }
}
