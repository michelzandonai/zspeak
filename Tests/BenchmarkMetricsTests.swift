import Testing
@testable import zspeak

@Suite("BenchmarkMetrics")
struct BenchmarkMetricsTests {

    @Test("WER exato deve ser 0")
    func testWordErrorRateExactMatch() {
        let wer = BenchmarkMetrics.wordErrorRate(expected: "Olá mundo bonito", actual: "olá mundo bonito")
        #expect(wer == 0)
    }

    @Test("WER com uma substituição em três palavras deve ser 1/3")
    func testWordErrorRateSingleSubstitution() {
        let wer = BenchmarkMetrics.wordErrorRate(expected: "olá mundo bonito", actual: "olá planeta bonito")
        #expect(abs(wer - (1.0 / 3.0)) < 0.0001)
    }

    @Test("CER detecta erro fino em palavra única")
    func testCharacterErrorRateDetectsFineGrainedError() {
        let cer = BenchmarkMetrics.characterErrorRate(expected: "deploy", actual: "depoly")
        #expect(cer > 0)
        #expect(cer < 0.5)
    }

    @Test("Pontuação e espaços extras não devem destruir WER")
    func testWordErrorRateIgnoresPunctuationAndWhitespaceNoise() {
        let wer = BenchmarkMetrics.wordErrorRate(
            expected: "Olá,   mundo!",
            actual: "olá mundo"
        )
        #expect(wer == 0)
    }

    @Test("accuracyScore é 1 - WER")
    func testAccuracyScoreDerivedFromWER() {
        let accuracy = BenchmarkMetrics.accuracyScore(
            expected: "olá mundo bonito",
            actual: "olá planeta bonito"
        )
        #expect(abs(accuracy - (2.0 / 3.0)) < 0.0001)
    }
}
