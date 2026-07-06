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

    // Regressão: CER preservava pontuação enquanto o WER a removia — um
    // modelo sem pontuação parecia pior no CER sem erro real de reconhecimento.
    @Test("CER usa a mesma normalização de pontuação do WER")
    func testCharacterErrorRateMatchesWERNormalization() {
        let cer = BenchmarkMetrics.characterErrorRate(
            expected: "Olá, mundo!",
            actual: "olá mundo"
        )
        #expect(cer == 0)
    }

    // Regressão: a tokenização `.byWords` quebrava "node.js" em 2 tokens,
    // dobrando a penalidade de um único termo técnico errado.
    @Test("Termos com ponto/hífen internos contam como um token só")
    func testTechnicalTokensStayWhole() {
        #expect(BenchmarkMetrics.canonicalWords("use node.js agora") == ["use", "node.js", "agora"])
        #expect(BenchmarkMetrics.canonicalWords("fez fast-forward na main") == ["fez", "fast-forward", "na", "main"])

        let wer = BenchmarkMetrics.wordErrorRate(
            expected: "use node.js agora",
            actual: "use nodejs agora"
        )
        #expect(abs(wer - (1.0 / 3.0)) < 0.0001)
    }

    @Test("Pontuação nas bordas do token é removida, símbolos internos ficam")
    func testEdgePunctuationTrimmed() {
        #expect(BenchmarkMetrics.canonicalWords("(git) push!") == ["git", "push"])
        #expect(BenchmarkMetrics.canonicalWords("rodar c++ hoje.") == ["rodar", "c++", "hoje"])
    }
}
