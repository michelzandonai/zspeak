import CoreMedia
import Foundation

/// As duas entradas usam o relógio de host do CoreAudio/CoreMedia, em segundos.
struct TimestampedAudioChunk: Sendable {
    let startTime: TimeInterval
    let samples: [Float]
}

func audioHostTime() -> TimeInterval {
    CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
}

/// Mistura duas fontes em 16 kHz mono, mantendo pausas e simultaneidade.
/// Nunca concatena fala e vídeo: cada buffer ocupa sua posição na linha do tempo.
final class AudioTimelineMixer: @unchecked Sendable {
    static let sampleRate = 16_000.0
    private static let pageSampleCount = 16_000
    private let sourceGain: Float
    private let origin: TimeInterval
    private let lock = NSLock()
    // Páginas de um segundo evitam realocar/copiar toda uma reunião dentro
    // do callback de áudio. A forma contígua só é materializada no stop.
    private var pages: [[Float]] = []
    private var sampleCount = 0
    private var emittedCount = 0
    private var observedSampleCount = 0
    private var finished = false

    init(origin: TimeInterval, sourceGain: Float = 0.5) {
        self.origin = origin
        self.sourceGain = sourceGain
    }

    func append(_ chunk: TimestampedAudioChunk) {
        guard chunk.startTime.isFinite, !chunk.samples.isEmpty else { return }
        let offset = (chunk.startTime - origin) * Self.sampleRate
        guard offset.isFinite, abs(offset) < Double(Int.max / 2) else { return }
        let start = Int(offset.rounded())
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        // Protege contra timestamps inválidos sem alocar horas de silêncio.
        guard start <= max(sampleCount, observedSampleCount) + Int(Self.sampleRate * 30) else { return }
        let skipped = max(0, -start)
        guard skipped < chunk.samples.count else { return }
        let end = start + chunk.samples.count
        guard end > 0 else { return }
        let requiredPages = (end + Self.pageSampleCount - 1) / Self.pageSampleCount
        while pages.count < requiredPages {
            pages.append([Float](repeating: 0, count: Self.pageSampleCount))
        }
        sampleCount = max(sampleCount, end)
        chunk.samples.withUnsafeBufferPointer { source in
            var index = skipped
            while index < source.count {
                let destination = start + index
                let pageIndex = destination / Self.pageSampleCount
                let pageOffset = destination % Self.pageSampleCount
                let count = min(source.count - index, Self.pageSampleCount - pageOffset)
                pages[pageIndex].withUnsafeMutableBufferPointer { page in
                    for offset in 0..<count {
                        let value = source[index + offset]
                        // Meio ganho por fonte evita saturação quando ambos falam juntos.
                        page[pageOffset + offset] += value.isFinite ? min(1, max(-1, value)) * sourceGain : 0
                    }
                }
                index += count
            }
        }
    }

    /// Folga curta para os callbacks das duas fontes chegarem antes de emitir.
    /// Buffers atrasados completam o resultado final sem repetir trechos no ASR ao vivo.
    func takeReady(upTo time: TimeInterval) -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        guard !finished, time.isFinite else { return [] }
        let offset = max(0, (time - origin) * Self.sampleRate)
        guard offset < Double(Int.max / 2) else { return [] }
        // O relógio continua avançando mesmo sem callbacks durante uma pausa.
        // Aceita o próximo play sem alocar silêncio enquanto não há áudio.
        observedSampleCount = max(observedSampleCount, Int(offset))
        let end = min(sampleCount, Int(offset))
        guard end > emittedCount else { return [] }
        let result = copySamples(in: emittedCount..<end)
        emittedCount = end
        return result
    }

    /// Devolve o áudio final e a cauda ainda não enviada à transcrição ao vivo.
    func finish() -> (samples: [Float], remainingLiveSamples: [Float]) {
        lock.lock()
        defer { lock.unlock() }
        finished = true
        let tail = copySamples(in: emittedCount..<sampleCount)
        var result: [Float] = []
        result.reserveCapacity(sampleCount)
        for index in pages.indices {
            let count = min(Self.pageSampleCount, sampleCount - result.count)
            result.append(contentsOf: pages[index].prefix(count))
            // Libera cada página assim que foi copiada, limitando o pico
            // transitório de memória ao transformar a gravação para o ASR.
            pages[index] = []
        }
        pages = []
        sampleCount = 0
        emittedCount = 0
        return (result, tail)
    }

    /// Chamado apenas com o lock adquirido; não expõe páginas mutáveis ao ASR.
    private func copySamples(in range: Range<Int>) -> [Float] {
        var result: [Float] = []
        result.reserveCapacity(range.count)
        var offset = range.lowerBound
        while offset < range.upperBound {
            let pageIndex = offset / Self.pageSampleCount
            let pageOffset = offset % Self.pageSampleCount
            let count = min(range.upperBound - offset, Self.pageSampleCount - pageOffset)
            result.append(contentsOf: pages[pageIndex][pageOffset..<(pageOffset + count)])
            offset += count
        }
        return result
    }
}
