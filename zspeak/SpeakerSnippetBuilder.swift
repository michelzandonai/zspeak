import Foundation

/// Constrói um snippet curto de áudio para identificação de um speaker.
/// Pega ~3 trechos espalhados ao longo da timeline (1º terço / meio / último terço)
/// e concatena para o usuário ouvir e nomear quem fala.
enum SpeakerSnippetBuilder {

    /// - Parameters:
    ///   - samples: áudio completo PCM 16 kHz mono float32
    ///   - segments: segmentos transcritos do arquivo todo
    ///   - speakerId: speakerId (ex.: "Speaker 0") cujos trechos serão extraídos
    ///   - sampleRate: taxa de amostragem dos samples (default 16000)
    ///   - totalSeconds: duração alvo do snippet (default ~10s)
    /// - Returns: samples concatenados (~totalSeconds), ou `[]` se não há fala suficiente
    static func buildSnippet(
        samples: [Float],
        segments: [TranscribedSegment],
        speakerId: String,
        sampleRate: Int = 16000,
        totalSeconds: Double = 10.0
    ) -> [Float] {
        let speakerSegments = segments
            .filter { $0.speakerId == speakerId }
            .sorted { $0.startTimeSeconds < $1.startTimeSeconds }

        guard !speakerSegments.isEmpty else { return [] }

        // Escolhe até 3 segmentos espalhados no tempo: primeiro, do meio, e último
        let picks: [TranscribedSegment]
        if speakerSegments.count == 1 {
            picks = [speakerSegments[0]]
        } else if speakerSegments.count == 2 {
            picks = speakerSegments
        } else {
            let mid = speakerSegments.count / 2
            picks = [
                speakerSegments[0],
                speakerSegments[mid],
                speakerSegments[speakerSegments.count - 1]
            ]
        }

        // Cada trecho corta no máximo totalSeconds/picks.count segundos
        let perPickSeconds = totalSeconds / Double(picks.count)
        let perPickSamples = Int(perPickSeconds * Double(sampleRate))
        let totalSamples = samples.count

        var result: [Float] = []
        result.reserveCapacity(Int(totalSeconds * Double(sampleRate)))

        for seg in picks {
            let startIdx = max(0, min(totalSamples, Int(seg.startTimeSeconds * Double(sampleRate))))
            let endIdxFull = max(startIdx, min(totalSamples, Int(seg.endTimeSeconds * Double(sampleRate))))
            let endIdx = min(endIdxFull, startIdx + perPickSamples)
            if endIdx > startIdx {
                result.append(contentsOf: samples[startIdx..<endIdx])
            }
        }

        return result
    }
}
