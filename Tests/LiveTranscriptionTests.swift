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
