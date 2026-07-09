import Foundation
import Testing
@testable import zspeak

@Suite("SpeechSignalConditioner")
struct SpeechSignalConditionerTests {

    /// Seno de teste em escala e frequência controladas.
    private func sine(frequencyHz: Float, amplitude: Float, seconds: Float = 1, sampleRate: Float = 16_000) -> [Float] {
        let count = Int(seconds * sampleRate)
        return (0..<count).map { index in
            amplitude * sin(2 * .pi * frequencyHz * Float(index) / sampleRate)
        }
    }

    private func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        return sqrt(samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count))
    }

    @Test("Normalização leva fala fraca ao RMS alvo")
    func normalizationBoostsQuietSpeech() {
        let quiet = sine(frequencyHz: 220, amplitude: 0.02)  // RMS ~0.014
        let normalized = SpeechSignalConditioner.normalizedLoudness(quiet)

        let resultRMS = rms(normalized)
        #expect(abs(resultRMS - SpeechSignalConditioner.targetRMS) < 0.01)
        #expect(normalized.count == quiet.count)
    }

    @Test("Normalização atenua gravação quente demais")
    func normalizationAttenuatesHotSignal() {
        let hot = sine(frequencyHz: 220, amplitude: 0.6)  // RMS ~0.42
        let normalized = SpeechSignalConditioner.normalizedLoudness(hot)

        #expect(abs(rms(normalized) - SpeechSignalConditioner.targetRMS) < 0.01)
    }

    @Test("Ganho respeita o teto e nunca introduz clipping")
    func normalizationNeverClips() {
        // Fala fraca com um pico isolado alto: o ganho pelo RMS estouraria o
        // pico — o limitador precisa reduzir o ganho para caber no teto.
        var samples = sine(frequencyHz: 220, amplitude: 0.02)
        samples[100] = 0.5

        let normalized = SpeechSignalConditioner.normalizedLoudness(samples)
        let peak = normalized.map(abs).max() ?? 0

        #expect(peak <= SpeechSignalConditioner.peakCeiling + 0.0001)
    }

    @Test("Silêncio passa intacto — ruído de fundo não é amplificado")
    func silencePassesUntouched() {
        let silence = [Float](repeating: 0.0002, count: 16_000)
        #expect(SpeechSignalConditioner.normalizedLoudness(silence) == silence)
        #expect(SpeechSignalConditioner.normalizedLoudness([]) == [])
    }

    @Test("Ganho máximo limita o boost de gravações quase mudas")
    func gainIsCapped() {
        let barelyAudible = sine(frequencyHz: 220, amplitude: 0.002)  // RMS ~0.0014
        let normalized = SpeechSignalConditioner.normalizedLoudness(barelyAudible)

        // RMS alvo exigiria ganho ~70×; o teto de 8× segura.
        let appliedGain = rms(normalized) / rms(barelyAudible)
        #expect(appliedGain <= SpeechSignalConditioner.maximumGain + 0.01)
    }

    @Test("High-pass remove DC e rumble, preserva a banda da voz")
    func highPassRemovesRumbleKeepsVoice() {
        // Rumble de 20 Hz é fortemente atenuado.
        let rumble = sine(frequencyHz: 20, amplitude: 0.5)
        let filteredRumble = SpeechSignalConditioner.highPassFiltered(rumble)
        #expect(rms(filteredRumble) < rms(rumble) * 0.35)

        // Voz em 300 Hz atravessa quase sem perda.
        let voice = sine(frequencyHz: 300, amplitude: 0.2)
        let filteredVoice = SpeechSignalConditioner.highPassFiltered(voice)
        #expect(rms(filteredVoice) > rms(voice) * 0.9)

        // Offset DC puro decai para ~zero.
        let dc = [Float](repeating: 0.3, count: 16_000)
        let filteredDC = SpeechSignalConditioner.highPassFiltered(dc)
        #expect(abs(filteredDC.last ?? 1) < 0.01)
    }

    @Test("Toggle desligado devolve o áudio intacto nas duas etapas")
    func toggleDisablesConditioning() {
        let defaults = UserDefaults(suiteName: "test-signal-conditioner")!
        defaults.removePersistentDomain(forName: "test-signal-conditioner")
        defaults.set(false, forKey: SpeechSignalConditioner.defaultsEnabledKey)

        let samples = sine(frequencyHz: 220, amplitude: 0.02)
        let trim = SpeechTrimResult(
            samples: samples,
            originalSampleCount: samples.count,
            startSampleIndex: 0,
            endSampleIndex: samples.count
        )

        #expect(SpeechSignalConditioner.highPassIfEnabled(samples, defaults: defaults) == samples)
        #expect(SpeechSignalConditioner.normalizingLoudnessIfEnabled(trim, defaults: defaults).samples == samples)

        // Default (sem chave) é ligado.
        defaults.removeObject(forKey: SpeechSignalConditioner.defaultsEnabledKey)
        #expect(SpeechSignalConditioner.isEnabled(defaults: defaults))
    }

    @Test("Normalização pós-trim preserva os metadados do trim")
    func normalizationPreservesTrimMetadata() {
        let samples = sine(frequencyHz: 220, amplitude: 0.02)
        let trim = SpeechTrimResult(
            samples: samples,
            originalSampleCount: 50_000,
            startSampleIndex: 8_000,
            endSampleIndex: 24_000
        )

        let conditioned = SpeechSignalConditioner.normalizingLoudnessIfEnabled(trim)

        #expect(conditioned.originalSampleCount == 50_000)
        #expect(conditioned.startSampleIndex == 8_000)
        #expect(conditioned.endSampleIndex == 24_000)
        #expect(abs(rms(conditioned.samples) - SpeechSignalConditioner.targetRMS) < 0.01)
    }
}

@Suite("AudioLevelMonitor clipping")
struct AudioLevelMonitorClippingTests {

    @Test("Pico clipado acende o aviso e decai após buffers limpos")
    func clippingFlagRaisesAndDecays() {
        let monitor = AudioLevelMonitor()
        #expect(!monitor.isClippingRecently())

        monitor.update(0.9, peak: 0.99)
        #expect(monitor.isClippingRecently())

        // Buffers limpos suficientes para o hold expirar.
        for _ in 0..<AudioLevelMonitor.clipHoldBufferCount {
            monitor.update(0.3, peak: 0.4)
        }
        #expect(!monitor.isClippingRecently())
    }

    @Test("Pico abaixo do limiar não acende; reset apaga na hora")
    func clippingThresholdAndReset() {
        let monitor = AudioLevelMonitor()

        monitor.update(0.9, peak: 0.9)
        #expect(!monitor.isClippingRecently())

        monitor.update(0.9, peak: 1.0)
        #expect(monitor.isClippingRecently())

        monitor.reset()
        #expect(!monitor.isClippingRecently())
        #expect(monitor.currentLevel() == 0)
    }
}
