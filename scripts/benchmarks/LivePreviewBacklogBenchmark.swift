import Foundation

/// Referência congelada de 4daadce, antes de limitar a busca a 12 s.
private enum LivePreviewCutReference {
    @inline(never)
    static func cut(samples: [Float], searchStart: Int, windowSize: Int) -> Int {
        let start = max(0, min(searchStart, samples.count - 1))
        let window = max(1, windowSize)
        guard samples.count - start > window else {
            return max(1, min(searchStart, samples.count))
        }
        let hop = max(1, window / 3)
        var quietestStart = start
        var quietestEnergy = Float.greatestFiniteMagnitude
        var index = start
        while index + window <= samples.count {
            var sum: Float = 0
            for sample in samples[index..<(index + window)] { sum += sample * sample }
            if sum < quietestEnergy {
                quietestEnergy = sum
                quietestStart = index
            }
            index += hop
        }
        return quietestStart + window / 2
    }
}

private final class PreviewBenchmarkResults: @unchecked Sendable {
    private let lock = NSLock()
    private var buffers: [[Float]] = []
    private var published = false
    func add(_ samples: [Float]) { lock.withLock { buffers.append(samples) } }
    func publish() { lock.withLock { published = true } }
    func snapshot() -> (buffers: [[Float]], published: Bool) { lock.withLock { (buffers, published) } }
}

@main
struct LivePreviewBacklogBenchmark {
    static func main() async throws {
        // Silêncio no fim reproduz o commit deslimitado, sem depender do modelo.
        var samples = [Float](repeating: 0.25, count: 40 * 16_000)
        samples.replaceSubrange((39 * 16_000)..<samples.count, with: repeatElement(0, count: 16_000))
        let referenceCut = LivePreviewCutReference.cut(samples: samples, searchStart: 128_000, windowSize: 3_840)
        precondition(referenceCut > 192_000, "A fixture precisa reproduzir o commit além de 12 s")

        let results = PreviewBenchmarkResults()
        let session = CumulativeLiveTranscriptionSession(
            transcribePreview: { samples in results.add(samples); return "trecho" },
            onUpdate: { _ in results.publish() }
        )
        await session.append(samples)
        let deadline = ContinuousClock.now + .seconds(5)
        while !results.snapshot().published && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        _ = try await session.finish()
        let snapshot = results.snapshot()
        let delivered = snapshot.buffers.flatMap { $0.dropLast(3_200).map(\.bitPattern) }
        let bitExact = delivered == samples.map(\.bitPattern)
        precondition(snapshot.published, "O backlog deveria terminar publicando um preview")
        precondition(bitExact, "A divisão em commits deve preservar todas as amostras e sua ordem")
        precondition(snapshot.buffers.allSatisfy { $0.count <= 195_200 }, "Inferência além de 12 s + padding")

        let iterations = 60
        let referenceTiming = timeSearch(samples: samples, iterations: iterations, bounded: false)
        let candidateTiming = timeSearch(samples: samples, iterations: iterations, bounded: true)
        let report: [String: Any] = [
            "benchmark": "live-preview-backlog",
            "scope": "synthetic cut search; no ASR inference",
            "audio_seconds": 40,
            "iterations": iterations,
            "audio_bit_exact": bitExact,
            "reference_first_commit_samples_with_padding": referenceCut + 3_200,
            "candidate_max_inference_samples_with_padding": snapshot.buffers.map(\.count).max() ?? 0,
            "candidate_inference_calls": snapshot.buffers.count,
            "reference_cut_search_ms": referenceTiming.milliseconds,
            "candidate_cut_search_ms": candidateTiming.milliseconds,
            "checksum": referenceTiming.checksum + candidateTiming.checksum
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }

    @inline(never)
    private static func timeSearch(samples: [Float], iterations: Int, bounded: Bool) -> (milliseconds: Double, checksum: Int) {
        let started = ContinuousClock.now
        var checksum = 0
        for iteration in 0..<iterations {
            // A entrada varia e todos os resultados são consumidos: impede
            // eliminar a medição como cálculo repetido sem efeito observável.
            let start = 128_000 + iteration % 64
            if bounded {
                checksum += CumulativeLiveTranscriptionSession.commitCutIndex(
                    samples: samples, searchStart: start, windowSize: 3_840, searchEnd: 192_000
                )
            } else {
                checksum += LivePreviewCutReference.cut(samples: samples, searchStart: start, windowSize: 3_840)
            }
        }
        let elapsed = started.duration(to: .now).components
        return (Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15, checksum)
    }
}
