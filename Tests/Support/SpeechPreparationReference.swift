import Foundation
#if canImport(zspeak)
@testable import zspeak
#endif

// Referência congelada da 1.0.64 para comparar waveform e transcrição.
// Não atualizar para acompanhar otimizações: qualquer diferença é uma regressão.
enum SpeechPreparationReference {
    static func highPassFiltered(
        _ samples: [Float],
        cutoffHz: Float = 90,
        sampleRate: Float = 16_000
    ) -> [Float] {
        guard samples.count > 1, cutoffHz > 0, sampleRate > 0 else { return samples }

        let rc = 1 / (2 * Float.pi * cutoffHz)
        let dt = 1 / sampleRate
        let alpha = rc / (rc + dt)

        var result = [Float](repeating: 0, count: samples.count)
        result[0] = samples[0]
        for index in 1..<samples.count {
            result[index] = alpha * (result[index - 1] + samples[index] - samples[index - 1])
        }
        return result
    }

    /// Normalização de loudness com ganho único: RMS → alvo, limitado pelo
    /// ganho máximo e pelo teto de pico. Silêncio passa intacto (não amplifica
    /// ruído de fundo); sinal já no alvo não é reprocessado.
    static func normalizedLoudness(_ samples: [Float]) -> [Float] {
        guard !samples.isEmpty else { return samples }

        var sumOfSquares: Float = 0
        var peak: Float = 0
        for sample in samples {
            sumOfSquares += sample * sample
            peak = max(peak, abs(sample))
        }
        let rms = sqrt(sumOfSquares / Float(samples.count))
        guard rms >= Float(0.001) else { return samples }

        var gain = min(Float(0.1) / rms, Float(8))
        if peak * gain > Float(0.95) {
            gain = Float(0.95) / peak
        }
        guard abs(gain - 1) > 0.01 else { return samples }

        return samples.map { max(-1, min(1, $0 * gain)) }
    }
    static func padded(_ samples: [Float], leading: Int, trailing: Int, minimumCount: Int) -> [Float] {
        if leading == 0 && trailing == 0 {
            return samples.count < minimumCount ? samples + [Float](repeating: 0, count: minimumCount - samples.count) : samples
        }
        let padded = [Float](repeating: 0, count: leading) + samples + [Float](repeating: 0, count: trailing)
        return padded.count < minimumCount ? padded + [Float](repeating: 0, count: minimumCount - padded.count) : padded
    }
}

// Gate RMS original: protege as margens e a escolha dos fonemas.
enum SpeechTrimReference {
    static func trimForASR(_ samples: [Float], sampleRate: Int = 16_000) -> SpeechTrimResult {
        guard sampleRate > 0 else {
            return SpeechTrimResult(
                samples: samples,
                originalSampleCount: samples.count,
                startSampleIndex: 0,
                endSampleIndex: samples.count
            )
        }

        let windowSize = max(1, Int(Double(sampleRate) * 0.020))
        let hopSize = max(1, Int(Double(sampleRate) * 0.010))
        let leadingPadding = Int(Double(sampleRate) * 0.120)
        let trailingPadding = Int(Double(sampleRate) * 0.180)

        guard samples.count >= windowSize else {
            return SpeechTrimResult(
                samples: samples,
                originalSampleCount: samples.count,
                startSampleIndex: 0,
                endSampleIndex: samples.count
            )
        }

        let frames = rmsFrames(samples: samples, windowSize: windowSize, hopSize: hopSize)
        // Gate absoluto de -54 dBFS (~0.002). O valor anterior (0.006, -44 dB)
        // descartava fala real de mics com ganho baixo (webcam, mic distante)
        // enquanto a waveform da UI — com floor de -58 dB — mostrava atividade.
        guard let maxRMS = frames.map(\.rms).max(), maxRMS >= 0.002 else {
            return SpeechTrimResult(
                samples: [],
                originalSampleCount: samples.count,
                startSampleIndex: samples.count,
                endSampleIndex: samples.count
            )
        }

        let threshold = speechThreshold(for: frames.map(\.rms), maxRMS: maxRMS)
        guard let firstActive = firstSustainedActiveFrame(frames, threshold: threshold),
              let lastActive = lastSustainedActiveFrame(frames, threshold: threshold) else {
            return SpeechTrimResult(
                samples: [],
                originalSampleCount: samples.count,
                startSampleIndex: samples.count,
                endSampleIndex: samples.count
            )
        }

        let start = max(0, frames[firstActive].startSample - leadingPadding)
        let end = min(samples.count, frames[lastActive].endSample + trailingPadding)
        guard start < end else {
            return SpeechTrimResult(
                samples: [],
                originalSampleCount: samples.count,
                startSampleIndex: samples.count,
                endSampleIndex: samples.count
            )
        }

        if start == 0 && end == samples.count {
            return SpeechTrimResult(
                samples: samples,
                originalSampleCount: samples.count,
                startSampleIndex: start,
                endSampleIndex: end
            )
        }

        return SpeechTrimResult(
            samples: Array(samples[start..<end]),
            originalSampleCount: samples.count,
            startSampleIndex: start,
            endSampleIndex: end
        )
    }

    private struct RMSFrame {
        let startSample: Int
        let endSample: Int
        let rms: Float
    }

    private static func rmsFrames(samples: [Float], windowSize: Int, hopSize: Int) -> [RMSFrame] {
        var frames: [RMSFrame] = []
        var start = 0

        while start + windowSize <= samples.count {
            var sumOfSquares: Float = 0
            for sample in samples[start..<(start + windowSize)] {
                sumOfSquares += sample * sample
            }

            frames.append(RMSFrame(
                startSample: start,
                endSample: start + windowSize,
                rms: sqrt(sumOfSquares / Float(windowSize))
            ))
            start += hopSize
        }

        return frames
    }

    private static func speechThreshold(for rmsValues: [Float], maxRMS: Float) -> Float {
        let sorted = rmsValues.sorted()
        let noiseIndex = min(sorted.count - 1, max(0, Int(Double(sorted.count) * 0.20)))
        let noiseFloor = sorted[noiseIndex]
        return min(max(0.002, noiseFloor * 3.5), maxRMS * 0.35)
    }

    private static func firstSustainedActiveFrame(_ frames: [RMSFrame], threshold: Float) -> Int? {
        for index in frames.indices {
            if activeCount(in: frames, range: index..<min(index + 3, frames.count), threshold: threshold) >= 2 {
                return index
            }
        }
        return nil
    }

    private static func lastSustainedActiveFrame(_ frames: [RMSFrame], threshold: Float) -> Int? {
        for index in frames.indices.reversed() {
            let lowerBound = max(frames.startIndex, index - 2)
            if activeCount(in: frames, range: lowerBound..<(index + 1), threshold: threshold) >= 2 {
                return index
            }
        }
        return nil
    }

    private static func activeCount(in frames: [RMSFrame], range: Range<Int>, threshold: Float) -> Int {
        var count = 0
        for index in range where frames[index].rms >= threshold {
            count += 1
        }
        return count
    }
}
