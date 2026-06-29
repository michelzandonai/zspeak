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
}
