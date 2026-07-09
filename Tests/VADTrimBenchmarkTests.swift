import Foundation
import Testing
@testable import zspeak

/// A/B do trim pré-ASR: gate RMS (baseline) vs Silero VAD (candidato), medido
/// sobre as fixtures reais do BenchmarkStore (gravações do usuário com texto
/// esperado revisado).
///
/// Rodar manualmente (usa modelo ASR real + fixtures locais):
///   ZSPEAK_RUN_VAD_TRIM_BENCHMARK=1 xcodebuild ... test \
///     -only-testing:'zspeakTests/VADTrimBenchmarkTests'
///
/// Use o resultado para decidir os defaults de `VADTrimSettings` — thresholds
/// e hangover podem ser variados via `defaults write` entre execuções.
@Suite("Benchmark A/B - trim RMS vs Silero VAD", .serialized)
@MainActor
struct VADTrimBenchmarkTests {

    @Test("compara WER/CER/latência dos dois trims", .timeLimit(.minutes(30)))
    func compareRMSvsVAD() async throws {
        guard ProcessInfo.processInfo.environment["ZSPEAK_RUN_VAD_TRIM_BENCHMARK"] == "1" else {
            print("SKIP: defina ZSPEAK_RUN_VAD_TRIM_BENCHMARK=1 para rodar o A/B de trim")
            return
        }

        let store = BenchmarkStore()
        guard !store.fixtures.isEmpty else {
            print("SKIP: sem fixtures de benchmark — grave fixtures na aba Benchmark antes")
            return
        }

        let transcriber = Transcriber()
        try await transcriber.initialize()
        let vadTrimmer = VADSpeechTrimmer()

        @Sendable func asr(_ samples: [Float]) async throws -> String {
            let prepared = AudioFileTranscriber.prepareSamplesForASR(
                samples,
                addBoundaryPadding: AudioFileTranscriber.shouldApplyPlainBoundaryPadding(
                    sampleCount: samples.count
                )
            )
            return try await transcriber.transcribe(prepared)
        }

        // Warm-up explícito do ASR: o warm-up interno do evaluateProfile passa
        // 1 s de zeros, que os trims descartam antes de chegar ao modelo —
        // sem isto, a primeira fixture do baseline pagaria o custo do ANE.
        _ = try? await asr([Float](repeating: 0, count: 16_000))
        // Aquece também o modelo VAD fora da medição.
        _ = await vadTrimmer.trimForASR([Float](repeating: 0, count: 16_000))

        let comparison = await store.compareProfiles(
            baselineName: "trim RMS",
            baseline: { samples in
                let trimmed = SpeechSampleTrimmer.trimForASR(samples).samples
                guard !trimmed.isEmpty else { return "" }
                return try await asr(trimmed)
            },
            candidateName: "trim Silero VAD",
            candidate: { samples in
                let result = await vadTrimmer.trimForASR(samples)
                    ?? SpeechSampleTrimmer.trimForASR(samples)
                guard !result.samples.isEmpty else { return "" }
                return try await asr(result.samples)
            }
        )

        print(render(comparison))

        // Segundo A/B: pipeline atual (VAD) vs pipeline com condicionamento de
        // sinal (high-pass pré-VAD + normalização de loudness pós-trim) — o
        // mesmo encadeamento usado em produção no hook trimSpeechForASR.
        let conditioningComparison = await store.compareProfiles(
            baselineName: "VAD sem condicionamento",
            baseline: { samples in
                let result = await vadTrimmer.trimForASR(samples)
                    ?? SpeechSampleTrimmer.trimForASR(samples)
                guard !result.samples.isEmpty else { return "" }
                return try await asr(result.samples)
            },
            candidateName: "VAD + condicionamento",
            candidate: { samples in
                let filtered = SpeechSignalConditioner.highPassFiltered(samples)
                let trimmed = await vadTrimmer.trimForASR(filtered)
                    ?? SpeechSampleTrimmer.trimForASR(filtered)
                let normalized = SpeechSignalConditioner.normalizedLoudness(trimmed.samples)
                guard !normalized.isEmpty else { return "" }
                return try await asr(normalized)
            }
        )

        print(render(conditioningComparison))
    }

    private func render(_ comparison: BenchmarkProfileComparison) -> String {
        func fmt(_ value: Double?) -> String {
            value.map { String(format: "%.4f", $0) } ?? "-"
        }

        var lines: [String] = []
        lines.append("== A/B trim pré-ASR ==")
        for summary in [comparison.baseline, comparison.candidate] {
            lines.append(
                "\(summary.profileName): WER=\(fmt(summary.averageWordErrorRate)) "
                    + "CER=\(fmt(summary.averageCharacterErrorRate)) "
                    + "lat=\(fmt(summary.averageLatency))s "
                    + "ok=\(summary.successfulCount)/\(summary.fixtureCount) falhas=\(summary.failedCount)"
            )
        }
        lines.append("delta WER (negativo = VAD melhor): \(fmt(comparison.wordErrorRateDelta))")
        lines.append("delta CER (negativo = VAD melhor): \(fmt(comparison.characterErrorRateDelta))")
        return lines.joined(separator: "\n")
    }
}
