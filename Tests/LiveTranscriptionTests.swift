import Foundation
import Testing
@testable import zspeak

@Suite("LiveTranscription")
struct LiveTranscriptionTests {

    @Test("Preview cumulativo publica prefixos crescentes")
    func cumulativePreviewPublishesGrowingPrefixes() async throws {
        let collector = LiveTranscriptionUpdateCollector()
        let session = CumulativeLiveTranscriptionSession(
            transcribePreview: { samples in
                try await Task.sleep(for: .milliseconds(10))
                return samples.count >= 30_000
                    ? "primeiro trecho segundo trecho"
                    : "primeiro trecho"
            },
            onUpdate: { update in
                collector.append(update)
            }
        )

        await session.append([Float](repeating: 0.05, count: 16_000))
        try await waitUntil(timeout: .seconds(1), interval: .milliseconds(10)) {
            collector.texts == ["primeiro trecho"]
        }

        await session.append([Float](repeating: 0.05, count: 12_000))
        try await waitUntil(timeout: .seconds(1), interval: .milliseconds(10)) {
            collector.texts == ["primeiro trecho", "primeiro trecho segundo trecho"]
        }
    }

    @Test("Preview cumulativo ignora audio menor que um segundo")
    func cumulativePreviewWaitsForEnoughAudio() async throws {
        let collector = LiveTranscriptionUpdateCollector()
        let session = CumulativeLiveTranscriptionSession(
            transcribePreview: { _ in "nao deveria publicar" },
            onUpdate: { update in
                collector.append(update)
            }
        )

        await session.append([Float](repeating: 0.05, count: 8_000))
        try await Task.sleep(for: .milliseconds(50))

        #expect(collector.texts.isEmpty)
    }

    // Regressão: sem o commit com janela, cada preview re-transcrevia a sessão
    // INTEIRA desde t=0 — custo O(n²) que atrasava o preview em ditados longos.
    @Test("Janela estourada commita o trecho antigo e limita o que é re-transcrito")
    func commitWindowBoundsPreviewSize() async throws {
        let collector = LiveTranscriptionUpdateCollector()
        let sizes = TranscribedSizeCollector()
        let session = CumulativeLiveTranscriptionSession(
            transcribePreview: { samples in
                sizes.add(samples.count)
                // 1ª chamada = chunk commitado; 2ª = janela restante
                return sizes.count == 1 ? "trecho confirmado" : "resto da janela"
            },
            onUpdate: { update in
                collector.append(update)
            }
        )

        // 13 s de áudio de uma vez — acima da janela de 12 s
        let totalSamples = 13 * 16_000
        await session.append([Float](repeating: 0.05, count: totalSamples))

        try await waitUntil(timeout: .seconds(2), interval: .milliseconds(10)) {
            collector.texts.count >= 2
        }

        // O texto confirmado vira prefixo estável do preview seguinte
        #expect(collector.texts.first == "trecho confirmado")
        #expect(collector.texts.last == "trecho confirmado resto da janela")

        // Nenhuma transcrição cobriu o áudio inteiro — a janela limitou o custo
        let maxTranscribed = sizes.maxCount
        #expect(maxTranscribed < totalSamples, "maior chamada=\(maxTranscribed), total=\(totalSamples)")
    }

    @Test("commitCutIndex corta no trecho mais silencioso após searchStart")
    func commitCutIndexPrefersQuietestRegion() {
        let sampleRate = 16_000
        var samples = [Float](repeating: 0.5, count: 12 * sampleRate)
        // Região quase silenciosa entre 9,375 s e 9,6875 s
        let silenceStart = 150_000
        let silenceEnd = 155_000
        for index in silenceStart..<silenceEnd {
            samples[index] = 0.001
        }

        let cut = CumulativeLiveTranscriptionSession.commitCutIndex(
            samples: samples,
            searchStart: 8 * sampleRate,
            windowSize: Int(0.240 * Double(sampleRate))
        )

        #expect(cut > silenceStart, "cut=\(cut) deveria cair dentro do silêncio")
        #expect(cut < silenceEnd, "cut=\(cut) deveria cair dentro do silêncio")
    }

    @Test("commitCutIndex degrada com segurança em buffer menor que a janela de busca")
    func commitCutIndexHandlesShortBuffer() {
        let samples = [Float](repeating: 0.1, count: 1_000)
        let cut = CumulativeLiveTranscriptionSession.commitCutIndex(
            samples: samples,
            searchStart: 128_000,
            windowSize: 3_840
        )
        #expect(cut >= 1)
        #expect(cut <= samples.count)
    }
}

/// Registra o tamanho dos buffers passados ao transcritor de preview.
private final class TranscribedSizeCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var sizes: [Int] = []

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return sizes.count
    }

    var maxCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return sizes.max() ?? 0
    }

    func add(_ size: Int) {
        lock.lock()
        sizes.append(size)
        lock.unlock()
    }
}

private final class LiveTranscriptionUpdateCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [LiveTranscriptionUpdate] = []

    var texts: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage.map(\.text)
    }

    func append(_ update: LiveTranscriptionUpdate) {
        lock.lock()
        storage.append(update)
        lock.unlock()
    }
}
