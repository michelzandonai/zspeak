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
///
/// Design "histórico rolante": cada ponto é uma amostra real do nível de voz.
/// O perfil da fala (sílabas e pausas) é preservado; a UI não injeta ondas
/// artificiais que façam a forma deixar de acompanhar quem está falando.
enum WaveformDynamics {
    private static let noiseGate: Float = 0.04
    private static let attackFactor: Float = 0.72
    private static let releaseFactor: Float = 0.35

    static func nextDisplayLevel(rawLevel: Float, previousLevel: Float) -> Float {
        let clamped = min(max(rawLevel, 0), 1)
        let gated: Float
        if clamped < noiseGate {
            gated = 0
        } else {
            gated = (clamped - noiseGate) / (1 - noiseGate)
        }

        // Curva quase linear: fala alta e fala média seguem visualmente
        // distintas, em vez de ambas colarem no topo da waveform.
        let shaped = pow(gated, 1.10)
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

    /// Posição X da barra que está `distanceFromNewest` amostras atrás da mais
    /// recente, com deslize contínuo durante o intervalo entre amostras
    /// (`sampleProgress` 0→1). Propriedade de continuidade: x(d, 1) == x(d+1, 0),
    /// então a rolagem nunca salta quando uma amostra nova chega.
    static func scrollingBarX(
        distanceFromNewest: Int,
        sampleProgress: CGFloat,
        pitch: CGFloat,
        rightmostX: CGFloat
    ) -> CGFloat {
        let clampedProgress = min(max(sampleProgress, 0), 1)
        return rightmostX - (CGFloat(distanceFromNewest) + clampedProgress) * pitch
    }

    /// Altura da barra a partir do nível amostrado (0–1). A curva côncava
    /// preserva dinâmica em fala média sem colar as barras no teto.
    static func scrollingBarHeight(
        level: Float,
        minimumHeight: CGFloat,
        maximumHeight: CGFloat
    ) -> CGFloat {
        let clamped = CGFloat(min(max(level, 0), 1))
        let minimum = max(0, minimumHeight)
        let maximum = max(minimum, maximumHeight)
        let shaped = pow(clamped, 0.66)
        return minimum + shaped * (maximum - minimum)
    }

    /// Opacidade da barra: recente e alta = brilhante; a cauda antiga esmaece
    /// para a esquerda. `positionProgress`: 0 = borda esquerda, 1 = direita.
    static func scrollingBarOpacity(level: Float, positionProgress: CGFloat) -> Double {
        let clampedLevel = Double(min(max(level, 0), 1))
        let position = Double(min(max(positionProgress, 0), 1))
        return min(0.25 + position * 0.42 + clampedLevel * 0.33, 0.97)
    }

    /// Respiração sutil da linha de base no silêncio — os pontos ondulam de
    /// leve para o overlay não parecer congelado enquanto ninguém fala.
    /// Determinística em função de (slot, phase); amplitude máxima ~0.08.
    static func idleBreathLevel(slot: Int, phase: TimeInterval) -> Float {
        let primary = (sin(phase * 1.9 + Double(slot) * 0.53) + 1) * 0.5
        let secondary = (sin(phase * 1.15 - Double(slot) * 0.87) + 1) * 0.5
        return Float(0.015 + primary * 0.045 + secondary * 0.02)
    }

    /// Suavização 3-tap leve (0.18/0.64/0.18) do perfil exibido: amostras
    /// vizinhas se conectam como onda em vez de pente serrilhado, preservando
    /// o contraste dos picos. Só afeta a exibição — o histórico fica intacto.
    static func smoothedProfile(_ samples: [Float]) -> [Float] {
        guard samples.count > 2 else { return samples }
        var result = samples
        for index in 1..<(samples.count - 1) {
            result[index] = samples[index - 1] * 0.18
                + samples[index] * 0.64
                + samples[index + 1] * 0.18
        }
        return result
    }

    /// Realce "cabeça de cometa": as barras mais recentes ganham um boost de
    /// brilho que decai em ~5 posições — dá a sensação de a voz estar sendo
    /// "escrita" agora na borda direita.
    static func recencyBoost(distanceFromNewest: Int) -> Double {
        let falloff = 1 - Double(distanceFromNewest) / 5
        return max(0, falloff) * 0.25
    }

    /// Lampejo transiente no ataque da fala: quando o nível sobe rápido entre
    /// duas amostras, a cabeça da onda ganha um brilho extra que decai em ~5
    /// barras — o início de cada sílaba "acende" a escrita.
    static func onsetBoost(attack: Float, distanceFromNewest: Int) -> Double {
        let clampedAttack = Double(min(max(attack, 0), 1))
        let falloff = max(0, 1 - Double(distanceFromNewest) / 5)
        return clampedAttack * falloff * 0.5
    }

    /// Quantas amostras o sampler deve registrar neste tick para manter a
    /// grade de tempo consistente. O relógio da rolagem assume UMA amostra a
    /// cada `samplePeriod` exato; se o loop dormir "período + trabalho" (ou
    /// acordar atrasado por pressão no MainActor), o atraso acumula e o
    /// `sampleProgress` fica saturado em 1 — a rolagem congela um instante a
    /// CADA amostra (micro-trava visível quando as barras são altas, i.e.
    /// falando). Com a grade agendada, um tick atrasado registra os slots
    /// devidos e o timestamp avança em múltiplos exatos do período.
    static func pendingSampleSlots(
        scheduledLastSampleAt: TimeInterval,
        now: TimeInterval,
        samplePeriod: TimeInterval,
        maximumSlots: Int
    ) -> Int {
        guard samplePeriod > 0, maximumSlots > 0, now > scheduledLastSampleAt else { return 0 }
        let slots = Int((now - scheduledLastSampleAt) / samplePeriod)
        return min(slots, maximumSlots)
    }

    /// Nível contínuo entre duas amostras: interpola a anterior e a atual no
    /// mesmo relógio da rolagem (sampleProgress 0→1). Elementos ambientes
    /// (glow, respiração) fluem a cada refresh em vez de pular a cada amostra.
    static func interpolatedLevel(previous: Float, current: Float, progress: Float) -> Float {
        let clampedProgress = min(max(progress, 0), 1)
        let clampedPrevious = min(max(previous, 0), 1)
        let clampedCurrent = min(max(current, 0), 1)
        return clampedPrevious + (clampedCurrent - clampedPrevious) * clampedProgress
    }

    /// Mantém a altura ligada à amostra real. `idleLevel` só dá uma respiração
    /// mínima no silêncio e nunca substitui a dinâmica da voz.
    static func audioDrivenLevel(sampleLevel: Float, idleLevel: Float) -> Float {
        max(
            min(max(sampleLevel, 0), 1),
            min(max(idleLevel, 0), 1)
        )
    }

    /// Converte energia de fala em meia-altura da fita visual. A curva é
    /// contínua e preserva a diferença entre voz baixa e alta, enquanto o
    /// piso mantém o HUD vivo no silêncio.
    static func ribbonAmplitude(
        level: Float,
        minimumAmplitude: CGFloat,
        maximumAmplitude: CGFloat
    ) -> CGFloat {
        let minimum = max(0, minimumAmplitude)
        let maximum = max(minimum, maximumAmplitude)
        let clamped = CGFloat(min(max(level, 0), 1))
        let shaped = pow(clamped, 0.70)
        return minimum + (maximum - minimum) * shaped
    }

    /// Controles Catmull-Rom convertidos para Bézier cúbica. A fita usa este
    /// cálculo para passar por cada amostra sem cantos nem mudanças bruscas de
    /// direção entre frames.
    static func ribbonBezierControls(
        previous: CGPoint,
        current: CGPoint,
        next: CGPoint,
        following: CGPoint,
        tension: CGFloat = 1
    ) -> (first: CGPoint, second: CGPoint) {
        let clampedTension = min(max(tension, 0), 1)
        let first = CGPoint(
            x: current.x + (next.x - previous.x) * clampedTension / 6,
            y: current.y + (next.y - previous.y) * clampedTension / 6
        )
        let second = CGPoint(
            x: next.x - (following.x - current.x) * clampedTension / 6,
            y: next.y - (following.y - current.y) * clampedTension / 6
        )
        return (first, second)
    }

    /// Seleciona máximos locais do áudio para os brilhos especulares. Como o
    /// critério acompanha a própria amostra (e não uma posição fixa da grade),
    /// o brilho desliza junto com o pico em vez de piscar a cada append.
    static func ribbonHighlightIndices(
        levels: [Float],
        threshold: Float = 0.32,
        maximumCount: Int = 5
    ) -> [Int] {
        guard !levels.isEmpty, maximumCount > 0 else { return [] }
        let clampedThreshold = min(max(threshold, 0), 1)
        var indices: [Int] = []

        for index in levels.indices {
            let level = min(max(levels[index], 0), 1)
            guard level >= clampedThreshold else { continue }

            let previous = index > levels.startIndex
                ? min(max(levels[index - 1], 0), 1)
                : -1
            let next = index < levels.index(before: levels.endIndex)
                ? min(max(levels[index + 1], 0), 1)
                : -1
            let isPeak = level >= previous
                && level >= next
                && (level > previous || level > next)
            if isPeak {
                indices.append(index)
            }
        }

        return Array(indices.suffix(maximumCount))
    }

    /// Entrada e saída suaves do brilho ao redor do limiar de fala. Evita um
    /// corte binário de opacidade quando o volume oscila próximo do threshold.
    static func ribbonHighlightOpacity(level: Float) -> Double {
        let normalized = min(max((level - 0.32) / 0.50, 0), 1)
        let smooth = normalized * normalized * (3 - 2 * normalized)
        return Double(smooth) * 0.72
    }

    /// Perfil determinístico de "fala" para snapshots/previews, onde não há
    /// áudio real: modulação curta (sílabas) sob um envelope longo (frases),
    /// escalado pelo nível forçado.
    static func syntheticSpeechHistory(count: Int, level: Float, phase: TimeInterval) -> [Float] {
        guard count > 0 else { return [] }
        let clampedLevel = Double(min(max(level, 0), 1))
        return (0..<count).map { index in
            let syllable = abs(sin(Double(index) * 0.82 + phase * 2.6))
            let envelope = 0.55 + 0.45 * sin(Double(index) * 0.21 - phase * 1.3)
            let value = clampedLevel * (0.16 + 0.84 * syllable * envelope)
            return Float(min(max(value, 0), 1))
        }
    }
}
