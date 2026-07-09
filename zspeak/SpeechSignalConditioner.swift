import Foundation

/// Condicionamento do sinal de fala antes do ASR.
///
/// Duas etapas, ambas baratas e determinísticas:
/// 1. High-pass 1ª ordem em ~90 Hz — remove rumble/vibração de mesa que não é
///    voz mas contamina o VAD e o modelo (aplicado ANTES do trim).
/// 2. Normalização de loudness — leva o RMS da fala aparada a um alvo
///    saudável (~-20 dBFS): gravação com mic distante ou ganho baixo chega ao
///    Parakeet no mesmo nível de uma gravação bem captada (aplicada DEPOIS do
///    trim, para o RMS não ser diluído pelo silêncio do pre-roll).
///
/// Desligável sem rebuild: `defaults write com.zspeak.app signalConditioningEnabled -bool NO`.
enum SpeechSignalConditioner {
    static let defaultsEnabledKey = "signalConditioningEnabled"

    /// RMS alvo (~-20 dBFS em escala linear).
    static let targetRMS: Float = 0.1
    /// Ganho máximo — evita amplificar ruído de fundo em gravações quase mudas.
    static let maximumGain: Float = 8
    /// Teto de pico pós-ganho — o ganho nunca introduz clipping digital.
    static let peakCeiling: Float = 0.95
    /// RMS mínimo para considerar que há sinal; abaixo é silêncio e passa intacto.
    static let minimumSignalRMS: Float = 0.001
    /// Corte do high-pass em Hz — fala útil vive acima disso.
    static let highPassCutoffHz: Float = 90
    static let sampleRate: Float = 16_000

    /// Toggle em UserDefaults — ligado por default.
    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: defaultsEnabledKey) != nil else { return true }
        return defaults.bool(forKey: defaultsEnabledKey)
    }

    /// Etapa 1 (pré-VAD), respeitando o toggle.
    static func highPassIfEnabled(_ samples: [Float], defaults: UserDefaults = .standard) -> [Float] {
        guard isEnabled(defaults: defaults) else { return samples }
        return highPassFiltered(samples)
    }

    /// Etapa 2 (pós-trim), respeitando o toggle. Preserva os metadados do trim.
    static func normalizingLoudnessIfEnabled(
        _ result: SpeechTrimResult,
        defaults: UserDefaults = .standard
    ) -> SpeechTrimResult {
        guard isEnabled(defaults: defaults) else { return result }
        let normalized = normalizedLoudness(result.samples)
        return SpeechTrimResult(
            samples: normalized,
            originalSampleCount: result.originalSampleCount,
            startSampleIndex: result.startSampleIndex,
            endSampleIndex: result.endSampleIndex
        )
    }

    /// High-pass de 1ª ordem (6 dB/oitava). Suficiente para rumble sem alterar
    /// o timbre da voz — filtros agressivos podem prejudicar o ASR.
    static func highPassFiltered(
        _ samples: [Float],
        cutoffHz: Float = highPassCutoffHz,
        sampleRate: Float = sampleRate
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
        guard rms >= minimumSignalRMS else { return samples }

        var gain = min(targetRMS / rms, maximumGain)
        if peak * gain > peakCeiling {
            gain = peakCeiling / peak
        }
        guard abs(gain - 1) > 0.01 else { return samples }

        return samples.map { max(-1, min(1, $0 * gain)) }
    }
}
