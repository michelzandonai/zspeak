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
    /// Transcrevendo chunk/segmento atual/total.
    /// Em modo .plain: chunks de 30s. Em modo .meeting: segmentos de speaker.
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
    nonisolated static let ffmpegExtensions: Set<String> = [
        "opus", "ogg", "oga", "wma", "amr", "3gp", "webm", "mka"
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
    ///   - onProgress: callback chamado em cada fase do processo
    func transcribe(
        url: URL,
        mode: Mode,
        numSpeakers: Int? = nil,
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

        if Self.ffmpegExtensions.contains(ext) {
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
        let samples: [Float]
        do {
            samples = try audioConverter.resampleAudioFile(workingURL)
        } catch {
            throw TranscriberError.audioLoadFailed(error.localizedDescription)
        }

        guard samples.count > 8000 else {  // Menos de 0.5s
            throw TranscriberError.emptyAudio
        }

        let durationSeconds = Double(samples.count) / 16000.0
        let sourceFileName = url.lastPathComponent

        // Fase 3: transcrição conforme modo
        switch mode {
        case .plain:
            // Para arquivos grandes, divide em chunks de 30s para reportar progresso
            // chunk a chunk e evitar transcrições gigantes em uma única chamada
            let chunks = Self.makeChunks(samples: samples)
            var collectedTexts: [String] = []
            collectedTexts.reserveCapacity(chunks.count)

            for (idx, chunk) in chunks.enumerated() {
                try Task.checkCancellation()
                onProgress(.transcribing(current: idx + 1, total: chunks.count))
                let chunkText: String
                do {
                    chunkText = try await transcribe(chunk)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw TranscriberError.transcriptionFailed(error.localizedDescription)
                }
                let trimmed = chunkText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    collectedTexts.append(trimmed)
                }
            }

            let finalText = collectedTexts.joined(separator: " ")
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

            // Se diarização retornou nada, faz fallback para texto corrido (com chunking)
            if speakerSegments.isEmpty {
                let chunks = Self.makeChunks(samples: samples)
                var collectedTexts: [String] = []
                for (idx, chunk) in chunks.enumerated() {
                    onProgress(.transcribing(current: idx + 1, total: chunks.count))
                    let text: String
                    do {
                        text = try await transcribe(chunk)
                    } catch {
                        throw TranscriberError.transcriptionFailed(error.localizedDescription)
                    }
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        collectedTexts.append(trimmed)
                    }
                }
                let finalText = collectedTexts.joined(separator: " ")
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
                    to: seg.endTimeSeconds
                )

                // Segmento muito curto: pula
                guard slice.count > 1600 else { continue }  // < 0.1s

                let segmentText: String
                do {
                    segmentText = try await transcribe(slice)
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

    /// Duração de cada chunk para transcrição em modo plain (segundos)
    nonisolated static let chunkDurationSeconds: Double = 30.0

    /// Limite mínimo para ativar chunking: arquivos < 60s são transcritos de uma vez
    nonisolated static let chunkingThresholdSeconds: Double = 60.0

    /// Divide samples em chunks de ~30s para transcrição progressiva.
    /// Função pura — testável. Áudios curtos retornam um único chunk.
    nonisolated static func makeChunks(
        samples: [Float],
        sampleRate: Int = 16000
    ) -> [[Float]] {
        let totalSeconds = Double(samples.count) / Double(sampleRate)

        // Áudio curto: retorna como um único chunk
        if totalSeconds <= chunkingThresholdSeconds {
            return [samples]
        }

        let chunkSize = Int(chunkDurationSeconds * Double(sampleRate))
        var chunks: [[Float]] = []
        var idx = 0
        while idx < samples.count {
            let end = min(idx + chunkSize, samples.count)
            chunks.append(Array(samples[idx..<end]))
            idx = end
        }
        return chunks
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
