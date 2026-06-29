import Foundation

/// Agrupa samples do tap em blocos maiores para consumidores em tempo real.
///
/// O tap do AVAudioEngine roda muitas vezes por segundo; chamar o ASR a cada
/// callback criaria pressão desnecessária no runtime. Este emitter acumula
/// samples 16 kHz mono e emite blocos maiores por callback síncrono.
final class LiveSampleEmitter: @unchecked Sendable {
    typealias Handler = @Sendable ([Float]) -> Void

    private let chunkSampleCount: Int
    private var buffer: [Float] = []
    private var handler: Handler?
    private let lock = NSLock()

    init(chunkSampleCount: Int) {
        self.chunkSampleCount = max(1, chunkSampleCount)
        buffer.reserveCapacity(self.chunkSampleCount * 2)
    }

    func reset(onSamples: Handler?) {
        lock.lock()
        buffer.removeAll(keepingCapacity: true)
        handler = onSamples
        lock.unlock()
    }

    func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }

        let chunks: [[Float]]
        let currentHandler: Handler?
        lock.lock()
        buffer.append(contentsOf: samples)
        currentHandler = handler

        if currentHandler == nil || buffer.count < chunkSampleCount {
            lock.unlock()
            return
        }

        var emitted: [[Float]] = []
        while buffer.count >= chunkSampleCount {
            emitted.append(Array(buffer.prefix(chunkSampleCount)))
            buffer.removeFirst(chunkSampleCount)
        }
        chunks = emitted
        lock.unlock()

        guard let currentHandler else { return }
        for chunk in chunks {
            currentHandler(chunk)
        }
    }

    func flush() {
        let chunk: [Float]
        let currentHandler: Handler?
        lock.lock()
        chunk = buffer
        buffer.removeAll(keepingCapacity: true)
        currentHandler = handler
        lock.unlock()

        guard let currentHandler, !chunk.isEmpty else { return }
        currentHandler(chunk)
    }

    func deactivate() {
        lock.lock()
        buffer.removeAll(keepingCapacity: true)
        handler = nil
        lock.unlock()
    }
}

/// Pipe síncrono para levar chunks de áudio do tap até uma Task consumidora.
final class LiveAudioChunkPipe: @unchecked Sendable {
    let stream: AsyncStream<[Float]>
    private let continuation: AsyncStream<[Float]>.Continuation

    init() {
        let pair = AsyncStream<[Float]>.makeStream()
        self.stream = pair.stream
        self.continuation = pair.continuation
    }

    func yield(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        continuation.yield(samples)
    }

    func finish() {
        continuation.finish()
    }
}
