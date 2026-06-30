import CoreGraphics
import Foundation

/// Normaliza energia de áudio para UI sem saturar fala normal.
enum AudioLevelNormalizer {
    private static let minimumRMS: Float = 0.000_001
    private static let noiseFloorDB: Float = -58
    private static let speechCeilingDB: Float = -12

    static func normalizedRMS(_ rms: Float) -> Float {
        guard rms.isFinite, rms > 0 else { return 0 }

        let db = 20 * log10(max(rms, minimumRMS))
        let normalized = (db - noiseFloorDB) / (speechCeilingDB - noiseFloorDB)
        return min(max(normalized, 0), 1)
    }
}

/// Modela a dinâmica visual da waveform do overlay.
enum WaveformDynamics {
    private static let noiseGate: Float = 0.04
    private static let attackFactor: Float = 0.72
    private static let releaseFactor: Float = 0.30

    static func nextDisplayLevel(rawLevel: Float, previousLevel: Float) -> Float {
        let clamped = min(max(rawLevel, 0), 1)
        let gated: Float
        if clamped < noiseGate {
            gated = 0
        } else {
            gated = (clamped - noiseGate) / (1 - noiseGate)
        }

        let shaped = pow(gated, 0.58)
        let previous = min(max(previousLevel, 0), 1)
        let factor = shaped > previous ? attackFactor : releaseFactor
        return previous + (shaped - previous) * factor
    }

    static func appending(_ value: Float, to history: [Float], capacity: Int) -> [Float] {
        guard capacity > 0 else { return [] }
        var next = history
        next.append(min(max(value, 0), 1))
        if next.count > capacity {
            next.removeFirst(next.count - capacity)
        }
        return next
    }

    static func chatGPTWaveformHistoryLevel(
        index: Int,
        count: Int,
        level: Float,
        history: [Float]
    ) -> Float {
        let clampedLevel = min(max(level, 0), 1)
        guard count > 1, history.count > 1 else { return clampedLevel }

        let clampedIndex = min(max(index, 0), count - 1)
        let progress = CGFloat(clampedIndex) / CGFloat(count - 1)
        let position = progress * CGFloat(history.count - 1)
        let lowerIndex = min(max(Int(floor(position)), 0), history.count - 1)
        let upperIndex = min(lowerIndex + 1, history.count - 1)
        let fraction = Float(position - CGFloat(lowerIndex))
        let lower = min(max(history[lowerIndex], 0), 1)
        let upper = min(max(history[upperIndex], 0), 1)
        let interpolated = lower + (upper - lower) * fraction

        return min(max(max(interpolated, clampedLevel * 0.18), 0), 1)
    }

    static func chatGPTWaveformBarEnergy(
        index: Int,
        count: Int,
        level: Float,
        history: [Float],
        phase: TimeInterval
    ) -> Float {
        let safeCount = max(count, 1)
        let clampedIndex = min(max(index, 0), safeCount - 1)
        let clampedLevel = min(max(level, 0), 1)
        let progress = safeCount == 1 ? CGFloat(0.5) : CGFloat(clampedIndex) / CGFloat(safeCount - 1)
        let centerEnvelope = Float(0.48 + pow(sin(progress * .pi), 0.78) * 0.52)
        let historyLevel = chatGPTWaveformHistoryLevel(
            index: clampedIndex,
            count: safeCount,
            level: clampedLevel,
            history: history
        )
        let primaryBreath = (sin(phase * 2.1 + Double(clampedIndex) * 0.74) + 1) * 0.5
        let secondaryBreath = (sin(phase * 1.35 - Double(clampedIndex) * 1.31) + 1) * 0.5
        let idleMotion = Float(0.050 + primaryBreath * 0.055 + secondaryBreath * 0.030)
        let historyAccent = max(historyLevel - clampedLevel * 0.30, 0) * 0.34
        let speechMotion = pow(max(historyLevel, clampedLevel * 0.52), 0.74) * centerEnvelope + historyAccent

        return min(max(idleMotion + speechMotion, 0), 1)
    }

    static func chatGPTWaveformBarHeight(
        index: Int,
        count: Int,
        level: Float,
        history: [Float],
        phase: TimeInterval,
        minimumHeight: CGFloat,
        maximumHeight: CGFloat
    ) -> CGFloat {
        let energy = CGFloat(chatGPTWaveformBarEnergy(
            index: index,
            count: count,
            level: level,
            history: history,
            phase: phase
        ))
        let minimum = max(0, minimumHeight)
        let maximum = max(minimum, maximumHeight)

        return minimum + energy * (maximum - minimum)
    }

    static func chatGPTWaveformBarOpacity(index: Int, count: Int, energy: Float) -> Double {
        let safeCount = max(count, 1)
        let clampedIndex = min(max(index, 0), safeCount - 1)
        let progress = safeCount == 1 ? CGFloat(0.5) : CGFloat(clampedIndex) / CGFloat(safeCount - 1)
        let centerEnvelope = Double(0.30 + pow(sin(progress * .pi), 0.85) * 0.70)
        let clampedEnergy = Double(min(max(energy, 0), 1))

        return min(0.34 + clampedEnergy * 0.46 + centerEnvelope * 0.18, 0.96)
    }
}
