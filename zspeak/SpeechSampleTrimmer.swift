import Foundation

struct SpeechTrimResult {
    let samples: [Float]
    let originalSampleCount: Int
    let startSampleIndex: Int
    let endSampleIndex: Int

    var removedSampleCount: Int {
        max(0, originalSampleCount - samples.count)
    }
}

/// Remove silêncio óbvio antes de mandar áudio ao ASR.
enum SpeechSampleTrimmer {
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
