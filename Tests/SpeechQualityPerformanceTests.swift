import FluidAudio
import Foundation
import Testing
@testable import zspeak

@Suite("ASR - Qualidade e desempenho A/B", .serialized, .disabled(
    if: ProcessInfo.processInfo.environment["ZSPEAK_TEST_ASR_QUALITY"] != "1",
    "Ative ZSPEAK_TEST_ASR_QUALITY=1 para comparar com o modelo Parakeet real."
))
struct SpeechQualityPerformanceTests {
    @Test("Otimização preserva waveform, texto, WER e CER em PT-BR, termos técnicos, fala baixa e ruído", .timeLimit(.minutes(10)))
    func realModelMatchesFrozenPreparation() async throws {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
        let converter = AudioConverter()
        let short = try converter.resampleAudioFile(fixtures.appendingPathComponent("pt-short.wav"))
        let long = try converter.resampleAudioFile(fixtures.appendingPathComponent("pt-long.wav"))
        let shortExpected = "Olá mundo, teste de transcrição local."
        let cases: [(String, [Float], String)] = [
            ("pt-short", short, shortExpected),
            ("pt-technical", long, "Hoje preciso ajustar o pipeline de deploy no Kubernetes. Também vou revisar o banco de dados PostgreSQL e conferir o cache do Redis. Depois abro um pull request com as alterações."),
            ("quiet-speech", short.map { $0 * 0.12 }, shortExpected),
            ("rumble-speech", short.enumerated().map { index, value in value + 0.03 * Float(sin(Double(index) * 2 * .pi * 25 / 16_000)) }, shortExpected),
            ("padded-speech", [Float](repeating: 0, count: 9_600) + short + [Float](repeating: 0, count: 9_600), shortExpected),
            ("silence", [Float](repeating: 0, count: 80_000), "")
        ]
        let transcriber = Transcriber()
        try await transcriber.initialize()
        _ = try await transcriber.transcribe([Float](repeating: 0, count: 16_000))
        let vad = VADSpeechTrimmer()
        let suite = "test-speech-quality-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        _ = await vad.trimForASR([Float](repeating: 0, count: 16_000), userDefaults: UserDefaults(suiteName: suite)!)
        var rows: [[String: Any]] = []
        for (name, samples, expected) in cases {
            let baselineFiltered = SpeechPreparationReference.highPassFiltered(samples)
            let filtered = SpeechSignalConditioner.highPassFiltered(samples)
            #expect(Self.identical(baselineFiltered, filtered))
            // O VAD e suas margens permanecem iguais. As duas alternativas
            // recebem os mesmos limites e as mesmas amostras da fala.
            let trimmed = await vad.trimForASR(filtered, userDefaults: UserDefaults(suiteName: suite)!) ?? SpeechSampleTrimmer.trimForASR(filtered)
            let oldNormalized = SpeechPreparationReference.normalizedLoudness(trimmed.samples)
            let normalized = SpeechSignalConditioner.normalizedLoudness(trimmed.samples)
            let padding = normalized.count <= 8 * 16_000 ? 4_000 : 0
            let baseline = SpeechPreparationReference.padded(oldNormalized, leading: padding, trailing: padding, minimumCount: 16_000)
            let candidate = AudioFileTranscriber.prepareSamplesForASR(normalized, addBoundaryPadding: padding > 0)
            #expect(Self.identical(baseline, candidate), "\(name): todos os bits enviados ao ASR devem ser iguais")
            var baselineTimes: [Double] = []
            var candidateTimes: [Double] = []
            var baselineText = ""
            var candidateText = ""
            for trial in 0..<3 {
                for before in trial % 2 == 0 ? [true, false] : [false, true] {
                    let started = ContinuousClock.now
                    let text = trimmed.samples.count >= 2_400 ? try await transcriber.transcribe(before ? baseline : candidate) : ""
                    let ms = Self.milliseconds(started.duration(to: .now))
                    if before { baselineText = text; baselineTimes.append(ms) }
                    else { candidateText = text; candidateTimes.append(ms) }
                    #expect(BenchmarkMetrics.wordErrorRate(expected: expected, actual: text) <= 0.65)
                }
                #expect(candidateText == baselineText, "\(name): texto final deve ser o mesmo")
            }
            let oldWER = BenchmarkMetrics.wordErrorRate(expected: expected, actual: baselineText)
            let newWER = BenchmarkMetrics.wordErrorRate(expected: expected, actual: candidateText)
            let oldCER = BenchmarkMetrics.characterErrorRate(expected: expected, actual: baselineText)
            let newCER = BenchmarkMetrics.characterErrorRate(expected: expected, actual: candidateText)
            #expect(newWER <= oldWER && newCER <= oldCER)
            if name == "silence" { #expect(candidateText.isEmpty) }
            print(String(format: "[QUALITY AB] %@ bit_exact=true same_text=%@ WER=%.4f/%.4f CER=%.4f/%.4f ASR_ms=%.2f/%.2f", name, candidateText == baselineText ? "true" : "false", oldWER, newWER, oldCER, newCER, baselineTimes.sorted()[1], candidateTimes.sorted()[1]))
            rows.append(["case": name, "audio_seconds": Double(samples.count) / 16_000,
                         "bit_exact": Self.identical(baseline, candidate), "same_text": candidateText == baselineText,
                         "baseline_wer": oldWER, "candidate_wer": newWER, "baseline_cer": oldCER, "candidate_cer": newCER,
                         "baseline_asr_ms": baselineTimes, "candidate_asr_ms": candidateTimes])
        }
        if let path = ProcessInfo.processInfo.environment["ZSPEAK_QUALITY_REPORT_PATH"] {
            let data = try JSONSerialization.data(withJSONObject: ["baseline_version": "1.0.64", "rows": rows], options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    private static func identical(_ lhs: [Float], _ rhs: [Float]) -> Bool {
        lhs.withUnsafeBytes { left in rhs.withUnsafeBytes { right in left.elementsEqual(right) } }
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }
}
