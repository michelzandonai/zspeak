import Foundation
import Testing
@testable import zspeak

@Suite("AudioSamplePadding - Qualidade preservada")
struct AudioSamplePaddingTests {
    @Test("Padding final e do preview é idêntico bit a bit à 1.0.64")
    func preservesEveryFloatBit() {
        let signal: [Float] = [-0.0, 0, 0.2, -0.9, .leastNonzeroMagnitude, .infinity, -.infinity, Float(bitPattern: 0x7FC00001)]
        for count in [0, 1, 160, 2_400, 16_000, 192_000] {
            let samples = (0..<count).map { signal[$0 % signal.count] }
            for padding in [(0, 0), (4_000, 4_000), (0, 3_200)] {
                let result = AudioSamplePadding.addingSilence(to: samples, leading: padding.0, trailing: padding.1, minimumCount: 16_000)
                let reference = SpeechPreparationReference.padded(samples, leading: padding.0, trailing: padding.1, minimumCount: 16_000)
                #expect(result.map(\.bitPattern) == reference.map(\.bitPattern))
            }
        }
    }

    @Test("Commit preserva range com índices não zero sem inserir fonemas de fora")
    func padsOnlySelectedRange() {
        let samples = (0..<200_000).map { Float($0) / 200_000 }
        let range = samples[12_345..<150_001]
        let reference = SpeechPreparationReference.padded(Array(range), leading: 0, trailing: 3_200, minimumCount: 16_000)
        let result = AudioSamplePadding.addingSilence(to: range, trailing: 3_200, minimumCount: 16_000)
        #expect(result == reference)
        #expect(Array(result.prefix(range.count)) == Array(range))
        #expect(result.suffix(3_200).allSatisfy { $0 == 0 })
    }

    @Test("Fallback RMS mantém as mesmas bordas em fala fraca e ruído")
    func preparationStillMatchesFrozenReference() {
        for amplitude in [Float(0), 0.001, 0.003, 0.02, 0.5] {
            var signal = [Float](repeating: 0, count: 8_000)
            signal += (0..<48_000).map { amplitude * sin(Float($0) * 0.09) }
            signal += [Float](repeating: 0, count: 8_000)
            let filtered = SpeechSignalConditioner.highPassFiltered(signal)
            #expect(filtered == SpeechPreparationReference.highPassFiltered(signal))
            let reference = SpeechTrimReference.trimForASR(filtered)
            let actual = SpeechSampleTrimmer.trimForASR(filtered)
            #expect(reference.startSampleIndex == actual.startSampleIndex)
            #expect(reference.endSampleIndex == actual.endSampleIndex)
            #expect(SpeechSignalConditioner.normalizedLoudness(actual.samples) == SpeechPreparationReference.normalizedLoudness(reference.samples))
        }
    }
}
