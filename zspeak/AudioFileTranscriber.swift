import Foundation
import FluidAudio
import os

/// Resultado de uma transcrição de arquivo
struct FileTranscriptionResult: Sendable {
    /// Texto final concatenado — para modo `.meeting`, inclui prefixos de speaker.
    /// Este é o texto copiado para clipboard e baixado como .txt
    let text: String

    /// Segmentos diarizados (apenas no modo `.meeting`)
    let segments: [TranscribedSegment]?

    let sourceFileName: String
    let durationSeconds: Double

    /// Samples PCM 16 kHz mono — usado pelo TranscriptionStore para salvar WAV no histórico
    let samples: [Float]
}

/// Segmento transcrito + identificação do interlocutor
struct TranscribedSegment: Identifiable, Sendable {
    let id = UUID()
    let speakerId: String
    let startTimeSeconds: Double
    let endTimeSeconds: Double
    let text: String
}

/// Progresso da transcrição de arquivo — exposto para UI mostrar fase atual
/// Alguns cases carregam progresso 0.0-1.0 para barra determinada; nil = indeterminado
enum FileTranscriptionPhase: Sendable, Equatable {
    /// ffmpeg convertendo formato não-nativo — progress 0.0-1.0 baseado em out_time_us / duration
    case transcoding(progress: Double?)
    /// Lendo e convertendo para 16 kHz mono (rápido, geralmente <1s)
    case loadingSamples
    /// Identificando speakers (modo meeting). `elapsed` é o tempo decorrido desde
    /// o início da chamada do diarizer, e `estimated` é uma estimativa baseada
    /// em RTFx ~8x. Não é progresso real (a lib não dá callback) — apenas honesto.
    case diarizing(elapsed: TimeInterval, estimated: TimeInterval)
    /// Transcrevendo etapa atual/total.
    /// Em modo .plain: single-pass do arquivo. Em modo .meeting: segmentos de speaker.
    case transcribing(current: Int, total: Int)
}

/// Orquestra o pipeline de transcrição de arquivos:
/// 1. Detecta formato (nativo vs ffmpeg)
/// 2. Se necessário, transcoda via ffmpeg para WAV temporário
/// 3. Carrega samples via FluidAudio.AudioConverter.resampleAudioFile
/// 4. Modo `.plain`: transcreve tudo de uma vez
/// 5. Modo `.meeting`: diariza primeiro e depois transcreve cada segmento
@MainActor
final class AudioFileTranscriber {

    enum Mode: String, Sendable, CaseIterable {
        case plain    // Texto corrido (sem identificar interlocutores)
        case meeting  // Com interlocutores (requer DiarizationManager)
    }

    enum TranscriberError: LocalizedError {
        case unsupportedFormat(extension: String)
        case ffmpegUnavailable
        case audioLoadFailed(String)
        case diarizerUnavailable
        case transcriptionFailed(String)
        case emptyAudio

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat(let ext):
                return "Formato .\(ext) não é suportado. Formatos aceitos: \(AudioFileTranscriber.supportedExtensions.sorted().map { ".\($0)" }.joined(separator: ", "))."
            case .ffmpegUnavailable:
                return "ffmpeg não disponível. Rode scripts/package_app.sh para gerar um bundle com ffmpeg embutido, ou instale via Homebrew em modo dev (brew install ffmpeg)."
            case .audioLoadFailed(let reason):
                return "Não foi possível ler o arquivo de áudio: \(reason)"
            case .diarizerUnavailable:
                return "Modo Reunião requer o DiarizationManager configurado no app."
            case .transcriptionFailed(let reason):
                return "Falha na transcrição: \(reason)"
            case .emptyAudio:
                return "O arquivo de áudio está vazio ou muito curto."
            }
        }
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.zspeak",
        category: "AudioFileTranscriber"
    )

    /// Formatos lidos diretamente por AVAudioFile (via FluidAudio.AudioConverter)
    nonisolated static let supportedNativeExtensions: Set<String> = [
        "wav", "mp3", "m4a", "aac", "flac", "aif", "aiff", "caf"
    ]

    /// Formatos que requerem transcodificação via ffmpeg
    /// Inclui containers de áudio E containers de vídeo (TASK-014) — ffmpeg
    /// extrai a trilha de áudio automaticamente e descarta o vídeo via `-vn`.
    nonisolated static let ffmpegExtensions: Set<String> = [
        // Áudio
        "opus", "ogg", "oga", "wma", "amr", "3gp", "webm", "mka",
        // Vídeo (extrai trilha de áudio via ffmpeg)
        "mp4", "mov", "m4v", "mkv", "avi", "wmv"
    ]

    /// Todos os formatos suportados (união dos acima)
    nonisolated static var supportedExtensions: Set<String> {
        supportedNativeExtensions.union(ffmpegExtensions)
    }

    private let audioConverter = AudioConverter()
    private let ffmpeg = FFmpegTranscoder.shared
    private let transcribe: ([Float]) async throws -> String
    private let diarizer: DiarizationManager?

    /// - Parameters:
    ///   - transcribe: closure que chama `AppState.transcribe(_:)` — injetado para facilitar testes
    ///   - diarizer: manager de diarização — necessário apenas para modo `.meeting`
    init(
        transcribe: @escaping ([Float]) async throws -> String,
        diarizer: DiarizationManager?
    ) {
        self.transcribe = transcribe
        self.diarizer = diarizer
    }

    /// Valida se a extensão do arquivo é suportada
    nonisolated static func isSupported(url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    /// Transcreve um arquivo de áudio
    /// - Parameters:
    ///   - url: arquivo de entrada (qualquer formato suportado)
    ///   - mode: `.plain` (texto corrido) ou `.meeting` (com interlocutores)
    ///   - preTranscodedURL: WAV 16 kHz mono já convertido por quem chamou
    ///     (usado pelo prefetch da `FileTranscriptionQueue`). Quando presente,
    ///     o passo de ffmpeg é pulado e o arquivo NÃO é apagado aqui — o dono
    ///     é quem passou.
    ///   - onProgress: callback chamado em cada fase do processo
    func transcribe(
        url: URL,
        mode: Mode,
        numSpeakers: Int? = nil,
        preTranscodedURL: URL? = nil,
        onProgress: @escaping @MainActor (FileTranscriptionPhase) -> Void
    ) async throws -> FileTranscriptionResult {
        let ext = url.pathExtension.lowercased()

        guard Self.supportedExtensions.contains(ext) else {
            throw TranscriberError.unsupportedFormat(extension: ext)
        }

        // Fase 1: transcodificação (se necessário)
        var workingURL = url
        var tempWAVToCleanup: URL?
        defer {
            if let temp = tempWAVToCleanup {
                try? FileManager.default.removeItem(at: temp)
            }
        }

        if let preTranscodedURL {
            workingURL = preTranscodedURL
        } else if Self.ffmpegExtensions.contains(ext) {
            guard FFmpegTranscoder.isAvailable else {
                throw TranscriberError.ffmpegUnavailable
            }
            onProgress(.transcoding(progress: nil))
            do {
                let tempWAV = try await ffmpeg.transcodeToWAV(inputURL: url) { progress in
                    Task { @MainActor in
                        onProgress(.transcoding(progress: progress))
                    }
                }
                workingURL = tempWAV
                tempWAVToCleanup = tempWAV
            } catch let error as FFmpegTranscoder.FFmpegError {
                throw TranscriberError.audioLoadFailed(error.localizedDescription)
            }
        }

        // Fase 2: carrega samples 16 kHz mono float32
        onProgress(.loadingSamples)
        let loadedSamples: [Float]
        do {
            loadedSamples = try audioConverter.resampleAudioFile(workingURL)
        } catch {
            throw TranscriberError.audioLoadFailed(error.localizedDescription)
        }

        let samples = Self.sanitizeSamples(loadedSamples)
        guard samples.count > 8000 else {  // Menos de 0.5s
            throw TranscriberError.emptyAudio
        }

        let durationSeconds = Double(samples.count) / 16000.0
        let sourceFileName = url.lastPathComponent

        // Fase 3: transcrição conforme modo
        switch mode {
        case .plain:
            let finalText = try await transcribePlain(samples: samples, onProgress: onProgress)
            return FileTranscriptionResult(
                text: finalText,
                segments: nil,
                sourceFileName: sourceFileName,
                durationSeconds: durationSeconds,
                samples: samples
            )

        case .meeting:
            guard let diarizer else {
                throw TranscriberError.diarizerUnavailable
            }

            // Polling cosmético: a lib não dá progresso real, então apenas reportamos
            // tempo decorrido + estimativa baseada em RTFx ~8x do diarizer FluidAudio
            let estimated = Double(samples.count) / 16000.0 / Self.diarizerRTFx
            let started = Date()
            onProgress(.diarizing(elapsed: 0, estimated: estimated))
            let pollTask = Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    if Task.isCancelled { return }
                    let elapsed = Date().timeIntervalSince(started)
                    onProgress(.diarizing(elapsed: elapsed, estimated: estimated))
                }
            }

            let speakerSegments: [SpeakerSegment]
            do {
                speakerSegments = try await diarizer.diarize(samples: samples, numSpeakers: numSpeakers)
                pollTask.cancel()
            } catch {
                pollTask.cancel()
                throw TranscriberError.transcriptionFailed(error.localizedDescription)
            }

            // Se diarização retornou nada, faz fallback para texto corrido.
            if speakerSegments.isEmpty {
                let finalText = try await transcribePlain(samples: samples, onProgress: onProgress)
                return FileTranscriptionResult(
                    text: finalText,
                    segments: nil,
                    sourceFileName: sourceFileName,
                    durationSeconds: durationSeconds,
                    samples: samples
                )
            }

            // Transcreve cada segmento individualmente
            var transcribedSegments: [TranscribedSegment] = []
            for (idx, seg) in speakerSegments.enumerated() {
                try Task.checkCancellation()
                onProgress(.transcribing(current: idx + 1, total: speakerSegments.count))

                let slice = DiarizationManager.slice(
                    samples: samples,
                    from: seg.startTimeSeconds,
                    to: seg.endTimeSeconds,
                    paddingSeconds: Self.diarizedSegmentPaddingSeconds
                )

                // Segmento muito curto: pula
                guard slice.count > 1600 else { continue }  // < 0.1s

                let segmentText: String
                do {
                    segmentText = try await transcribe(Self.prepareSamplesForASR(slice))
                } catch {
                    Self.logger.error("Segmento \(idx) falhou: \(error.localizedDescription, privacy: .public)")
                    continue
                }

                let trimmed = segmentText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }

                transcribedSegments.append(TranscribedSegment(
                    speakerId: seg.speakerId,
                    startTimeSeconds: seg.startTimeSeconds,
                    endTimeSeconds: seg.endTimeSeconds,
                    text: trimmed
                ))
            }

            // Monta texto final com prefixo de speaker + timestamp
            let finalText = transcribedSegments
                .map { "\(Self.formatTimestamp($0.startTimeSeconds)) \($0.speakerId): \($0.text)" }
                .joined(separator: "\n\n")

            return FileTranscriptionResult(
                text: finalText,
                segments: transcribedSegments,
                sourceFileName: sourceFileName,
                durationSeconds: durationSeconds,
                samples: samples
            )
        }
    }

    private func transcribePlain(
        samples: [Float],
        onProgress: @escaping @MainActor (FileTranscriptionPhase) -> Void
    ) async throws -> String {
        try Task.checkCancellation()
        onProgress(.transcribing(current: 1, total: 1))

        do {
            let shouldPadBoundaries = Self.shouldApplyPlainBoundaryPadding(sampleCount: samples.count)
            let text = try await transcribe(Self.prepareSamplesForASR(
                samples,
                addBoundaryPadding: shouldPadBoundaries
            ))
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw TranscriberError.transcriptionFailed(error.localizedDescription)
        }
    }

    /// Duração do chunk de fallback manual. O caminho principal usa single-pass
    /// para deixar o `AsrManager` aplicar o chunking interno com estado do decoder.
    nonisolated static let chunkDurationSeconds: Double = 45.0

    /// Overlap do fallback manual para reduzir corte de fonemas/palavras na borda.
    nonisolated static let chunkOverlapSeconds: Double = 1.0

    /// Limite mínimo para ativar fallback manual: arquivos < 60s usam um único range.
    nonisolated static let chunkingThresholdSeconds: Double = 60.0

    /// Padding aplicado ao redor de segmentos diarizados para não cortar fonemas.
    nonisolated static let diarizedSegmentPaddingSeconds: Double = 0.35

    /// Silêncio sintético nas bordas do áudio enviado ao ASR. Ajuda o encoder a
    /// não perder a primeira/última sílaba em arquivos que começam "secos".
    nonisolated static let asrBoundaryPaddingSeconds: Double = 0.25

    /// Para texto corrido, padding de borda é mais útil em frases curtas. Em
    /// arquivos longos, o chunker interno do FluidAudio já tem contexto suficiente.
    nonisolated static let plainBoundaryPaddingMaxDurationSeconds: Double = 8.0

    /// Divide samples em chunks de fallback com overlap.
    /// Função pura — testável. Áudios curtos retornam um único chunk.
    nonisolated static func makeChunks(
        samples: [Float],
        sampleRate: Int = 16000
    ) -> [[Float]] {
        makeChunkRanges(sampleCount: samples.count, sampleRate: sampleRate).map { range in
            Array(samples[range])
        }
    }

    /// Divide o áudio em ranges de fallback sem pré-alocar todos os chunks.
    nonisolated static func makeChunkRanges(
        sampleCount: Int,
        sampleRate: Int = 16000
    ) -> [Range<Int>] {
        let totalSeconds = Double(sampleCount) / Double(sampleRate)

        // Áudio curto: retorna como um único chunk
        if totalSeconds <= chunkingThresholdSeconds {
            return [0..<sampleCount]
        }

        let chunkSize = max(1, Int(chunkDurationSeconds * Double(sampleRate)))
        let overlapSize = max(0, min(chunkSize - 1, Int(chunkOverlapSeconds * Double(sampleRate))))
        var ranges: [Range<Int>] = []
        var idx = 0
        while idx < sampleCount {
            let end = min(idx + chunkSize, sampleCount)
            ranges.append(idx..<end)
            if end == sampleCount { break }
            idx = max(idx + 1, end - overlapSize)
        }
        return ranges
    }

    /// Garante amostras finitas dentro do intervalo esperado por CoreML.
    nonisolated static func sanitizeSamples(_ samples: [Float]) -> [Float] {
        samples.map { sample in
            guard sample.isFinite else { return 0 }
            return min(1, max(-1, sample))
        }
    }

    /// O ASR do FluidAudio exige pelo menos 1s de áudio. Para capturas/segmentos
    /// curtos válidos, completamos com silêncio em vez de falhar a transcrição.
    nonisolated static func padSamplesForASRIfNeeded(
        _ samples: [Float],
        sampleRate: Int = 16000
    ) -> [Float] {
        guard samples.count < sampleRate else { return samples }
        return samples + Array(repeating: 0, count: sampleRate - samples.count)
    }

    /// Prepara áudio de arquivo/segmento para o ASR priorizando assertividade:
    /// padding silencioso nas bordas + mínimo de 1s exigido pelo FluidAudio.
    nonisolated static func prepareSamplesForASR(
        _ samples: [Float],
        sampleRate: Int = 16000,
        addBoundaryPadding: Bool = true
    ) -> [Float] {
        guard addBoundaryPadding else {
            return padSamplesForASRIfNeeded(samples, sampleRate: sampleRate)
        }

        let paddingCount = max(0, Int(asrBoundaryPaddingSeconds * Double(sampleRate)))
        guard paddingCount > 0 else {
            return padSamplesForASRIfNeeded(samples, sampleRate: sampleRate)
        }

        let padded = Array(repeating: Float(0), count: paddingCount)
            + samples
            + Array(repeating: Float(0), count: paddingCount)
        return padSamplesForASRIfNeeded(padded, sampleRate: sampleRate)
    }

    nonisolated static func shouldApplyPlainBoundaryPadding(
        sampleCount: Int,
        sampleRate: Int = 16000
    ) -> Bool {
        Double(sampleCount) / Double(sampleRate) <= plainBoundaryPaddingMaxDurationSeconds
    }

    /// Real-time factor empírico do diarizer FluidAudio em Apple Silicon (~8x)
    nonisolated static let diarizerRTFx: Double = 8.0

    /// Sub-fase cosmética da diarização baseada em % do tempo decorrido vs estimado.
    /// Função pura — testável.
    nonisolated static func diarizingSubphase(elapsed: TimeInterval, estimated: TimeInterval) -> String {
        guard estimated > 0 else { return "Identificando interlocutores..." }
        let ratio = elapsed / estimated
        if ratio > 1.0 {
            return "Finalizando..."
        } else if ratio >= 0.8 {
            return "Agrupando interlocutores..."
        } else if ratio >= 0.3 {
            return "Extraindo características vocais..."
        } else {
            return "Analisando segmentos de voz..."
        }
    }

    /// Formata segundos como [HH:MM:SS] ou [MM:SS]
    nonisolated static func formatTimestamp(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "[%02d:%02d:%02d]", h, m, s)
        }
        return String(format: "[%02d:%02d]", m, s)
    }
}
