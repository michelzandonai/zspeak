import Foundation
import Testing
@testable import zspeak

@Suite("SpeechSampleTrimmer")
struct SpeechSampleTrimmerTests {

    @Test("Remove silencio de inicio e fim preservando margem da fala")
    func removeSilencioComMargem() {
        let sampleRate = 16_000
        let leadingSilence = [Float](repeating: 0, count: sampleRate / 2)
        let speech = [Float](repeating: 0.05, count: sampleRate)
        let trailingSilence = [Float](repeating: 0, count: sampleRate / 2)
        let samples = leadingSilence + speech + trailingSilence

        let result = SpeechSampleTrimmer.trimForASR(samples, sampleRate: sampleRate)

        #expect(result.samples.count < samples.count)
        #expect(result.samples.count > speech.count)
        #expect(result.startSampleIndex < leadingSilence.count)
        #expect(result.startSampleIndex >= leadingSilence.count - 3_200)
        #expect(result.endSampleIndex > leadingSilence.count + speech.count)
        #expect(result.endSampleIndex <= leadingSilence.count + speech.count + 3_600)
    }

    @Test("Silencio puro retorna vazio para pular ASR")
    func silencioPuroRetornaVazio() {
        let samples = [Float](repeating: 0, count: 32_000)

        let result = SpeechSampleTrimmer.trimForASR(samples)

        #expect(result.samples.isEmpty)
        #expect(result.removedSampleCount == samples.count)
    }

    @Test("Fala continua nao e aparada")
    func falaContinuaNaoApara() {
        let samples = [Float](repeating: 0.03, count: 16_000)

        let result = SpeechSampleTrimmer.trimForASR(samples)

        #expect(result.samples.count == samples.count)
        #expect(result.startSampleIndex == 0)
        #expect(result.endSampleIndex == samples.count)
    }
}
