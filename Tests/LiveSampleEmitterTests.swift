import Foundation
import Testing
@testable import zspeak

@Suite("LiveSampleEmitter")
struct LiveSampleEmitterTests {

    @Test("Emite apenas quando atinge o tamanho do chunk")
    func emiteQuandoAtingeChunk() {
        let emitter = LiveSampleEmitter(chunkSampleCount: 4)
        let collector = ChunkCollector()
        emitter.reset { samples in
            collector.append(samples)
        }

        emitter.append([1, 2])
        #expect(collector.chunks.isEmpty)

        emitter.append([3, 4])
        #expect(collector.chunks == [[1, 2, 3, 4]])
    }

    @Test("Flush emite chunk parcial final")
    func flushEmiteParcial() {
        let emitter = LiveSampleEmitter(chunkSampleCount: 4)
        let collector = ChunkCollector()
        emitter.reset { samples in
            collector.append(samples)
        }

        emitter.append([1, 2, 3])
        emitter.flush()

        #expect(collector.chunks == [[1, 2, 3]])
    }

    @Test("Deactivate descarta buffer e handler")
    func deactivateDescartaBufferEHandler() {
        let emitter = LiveSampleEmitter(chunkSampleCount: 4)
        let collector = ChunkCollector()
        emitter.reset { samples in
            collector.append(samples)
        }

        emitter.append([1, 2, 3])
        emitter.deactivate()
        emitter.flush()
        emitter.append([4, 5, 6, 7])

        #expect(collector.chunks.isEmpty)
    }

    @Test("Buffer grande após parcial emite cada sample em ordem, exatamente uma vez")
    func largeBurstAfterPartialKeepsSampleOrder() {
        let emitter = LiveSampleEmitter(chunkSampleCount: 4_000)
        let collector = ChunkCollector()
        emitter.reset { collector.append($0) }
        let samples = (0..<480_007).map { Float($0) }
        emitter.append(Array(samples.prefix(7)))
        emitter.append(Array(samples.dropFirst(7)))
        emitter.flush()
        #expect(collector.chunks.count == 121)
        #expect(collector.chunks.dropLast().allSatisfy { $0.count == 4_000 })
        #expect(collector.chunks.last?.count == 7)
        #expect(collector.chunks.flatMap { $0 } == samples)
    }
}

private final class ChunkCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [[Float]] = []

    var chunks: [[Float]] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ samples: [Float]) {
        lock.lock()
        storage.append(samples)
        lock.unlock()
    }
}
