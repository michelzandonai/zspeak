import Foundation
import FluidAudio
import Testing
@testable import zspeak

@Suite("LiveTranscription Benchmark", .serialized)
struct LiveTranscriptionBenchmarkTests {

    private static let fixturesDir: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
    }()

    private static var shouldRun: Bool {
        let runFlag = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("build", isDirectory: true)
            .appendingPathComponent("run-live-transcription-benchmark.flag")

        return ProcessInfo.processInfo.environment["ZSPEAK_RUN_LIVE_BENCHMARK"] == "1"
            || FileManager.default.fileExists(atPath: runFlag.path)
    }

    @Test(
        "benchmark streaming publica parciais crescentes em pt-long.wav",
        .timeLimit(.minutes(10))
    )
    func streamingPublishesGrowingPartials() async throws {
        guard Self.shouldRun else {
            print("SKIP: defina ZSPEAK_RUN_LIVE_BENCHMARK=1 ou crie build/run-live-transcription-benchmark.flag")
            return
        }

        let audioURL = Self.fixturesDir.appendingPathComponent("pt-long.wav")
        let samples = try AudioConverter().resampleAudioFile(audioURL)

        let transcriber = Transcriber()
        try await transcriber.initialize()

        let collector = LiveUpdateCollector()
        let startedAt = Date()
        let session = try await transcriber.startLiveTranscription { update in
            collector.append(update, elapsed: Date().timeIntervalSince(startedAt))
        }

        let chunkSampleCount = 4_000 // 250 ms em 16 kHz, igual ao microfone.
        var offset = 0
        while offset < samples.count {
            let end = min(offset + chunkSampleCount, samples.count)
            await session.append(Array(samples[offset..<end]))
            offset = end
            try await Task.sleep(for: .milliseconds(250))
        }

        let finalText = try await session.finish()
        let events = collector.snapshot()
        let lengths = events.map { $0.update.text.count }
        let growingSteps = zip(lengths, lengths.dropFirst()).filter { $1 > $0 }.count
        let intervals = zip(events, events.dropFirst()).map { $1.elapsed - $0.elapsed }
        let firstLatency = events.first?.elapsed ?? -1
        let maxGap = intervals.max() ?? 0
        let averageGap = intervals.isEmpty ? 0 : intervals.reduce(0, +) / Double(intervals.count)

        print(String(
            format: "[LIVE BENCH] audio=%.2fs updates=%d growth=%d first=%.2fs avgGap=%.2fs maxGap=%.2fs finalChars=%d",
            Double(samples.count) / 16_000.0,
            events.count,
            growingSteps,
            firstLatency,
            averageGap,
            maxGap,
            finalText.count
        ))

        for event in events.prefix(12) {
            print(String(
                format: "[LIVE UPDATE] +%.2fs confirmed=%@ chars=%d text=\"%@\"",
                event.elapsed,
                event.update.isConfirmed ? "true" : "false",
                event.update.text.count,
                event.update.text
            ))
        }

        #expect(events.count >= 3, "Esperava pelo menos 3 updates ao vivo; recebeu \(events.count).")
        #expect(growingSteps >= 2, "Esperava parciais crescendo; comprimentos: \(lengths).")
        #expect(firstLatency >= 0 && firstLatency <= 3.0, "Primeiro parcial demorou \(firstLatency)s.")
        #expect(maxGap <= 4.0, "Gap máximo entre updates ficou alto demais: \(maxGap)s.")
        #expect(!finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}

private final class LiveUpdateCollector: @unchecked Sendable {
    struct Event: Sendable {
        let elapsed: TimeInterval
        let update: LiveTranscriptionUpdate
    }

    private let lock = NSLock()
    private var events: [Event] = []

    func append(_ update: LiveTranscriptionUpdate, elapsed: TimeInterval) {
        lock.lock()
        events.append(Event(elapsed: elapsed, update: update))
        lock.unlock()
    }

    func snapshot() -> [Event] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}
