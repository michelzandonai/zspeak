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
            !collector.texts.isEmpty
        }

        // O commit não publica sozinho — o preview seguinte publica o texto
        // completo (confirmado + janela) de uma vez, sem encolher na tela.
        #expect(collector.texts == ["trecho confirmado resto da janela"])

        // Nenhuma transcrição cobriu o áudio inteiro — a janela limitou o custo
        let maxTranscribed = sizes.maxCount
        #expect(maxTranscribed < totalSamples, "maior chamada=\(maxTranscribed), total=\(totalSamples)")
    }

    // Regressão do bug "texto some e volta" no overlay: ao estourar a janela,
    // o commit publicava só o texto confirmado — o preview da janela corrente
    // sumia da tela e era redigitado logo depois, praticamente igual.
    @Test("Commit não publica texto encolhido durante a gravação")
    func commitDoesNotPublishShrunkText() async throws {
        let collector = LiveTranscriptionUpdateCollector()
        let calls = TranscribedSizeCollector()
        let session = CumulativeLiveTranscriptionSession(
            transcribePreview: { samples in
                calls.add(samples.count)
                switch calls.count {
                case 1: return "alpha bravo charlie delta echo"   // preview de 11 s
                case 2: return "alpha bravo"                      // chunk commitado
                default: return "charlie delta echo foxtrot"      // janela restante
                }
            },
            onUpdate: { update in
                collector.append(update)
            }
        )

        // 11 s → preview normal publica o texto longo
        await session.append([Float](repeating: 0.05, count: 11 * 16_000))
        try await waitUntil(timeout: .seconds(2), interval: .milliseconds(10)) {
            collector.texts.count == 1
        }

        // +2 s → estoura a janela de 12 s e dispara o commit
        await session.append([Float](repeating: 0.05, count: 2 * 16_000))
        try await waitUntil(timeout: .seconds(2), interval: .milliseconds(10)) {
            collector.texts.count >= 2
        }

        // Nenhum texto publicado pode ser mais curto que o anterior — o
        // overlay nunca deve ver o texto "encolher" por causa do commit.
        let texts = collector.texts
        for (previous, next) in zip(texts, texts.dropFirst()) {
            #expect(
                next.count >= previous.count,
                "texto encolheu de \"\(previous)\" para \"\(next)\""
            )
        }
        #expect(texts.last == "alpha bravo charlie delta echo foxtrot")
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

    @Test("Stop espera a inferência cancelada e não publica resultado atrasado")
    func finishDrainsActiveInferenceWithoutPublishing() async throws {
        let gate = ControlledPreviewInference()
        let collector = LiveTranscriptionUpdateCollector()
        let session = CumulativeLiveTranscriptionSession(
            transcribePreview: { _ in await gate.transcribe() },
            onUpdate: { collector.append($0) }
        )
        await session.append([Float](repeating: 0.05, count: 16_000))
        try await waitUntil { await gate.isActive }
        let completed = AtomicInt()
        let finishing = Task { _ = try await session.finish(); completed.increment() }
        try await Task.sleep(for: .milliseconds(30))
        #expect(completed.current == 0, "Batch final deve aguardar a prediction ainda ativa")
        await session.append([Float](repeating: 0.05, count: 12_000))
        await gate.release()
        try await finishing.value
        #expect(completed.current == 1)
        #expect(await gate.callCount == 1, "Audio da cauda não deve disparar outro preview no stop")
        #expect(collector.texts.isEmpty)
    }

    @Test("Preview e commit enviam exatamente os mesmos samples e padding da versão anterior")
    func previewAndCommitKeepExactAudio() async throws {
        let collector = PreviewSignalCollector()
        let signal = (0..<208_000).map { Float($0 % 23 - 11) / 200 }
        let session = CumulativeLiveTranscriptionSession(
            transcribePreview: { samples in collector.add(samples); return "fala" },
            onUpdate: { _ in }
        )
        await session.append(signal)
        try await waitUntil { collector.buffers.count >= 2 }
        let cut = CumulativeLiveTranscriptionSession.commitCutIndex(samples: signal, searchStart: 128_000, windowSize: 3_840)
        let expectedCommit = SpeechPreparationReference.padded(Array(signal[..<cut]), leading: 0, trailing: 3_200, minimumCount: 16_000)
        let expectedPreview = SpeechPreparationReference.padded(Array(signal[cut...]), leading: 0, trailing: 3_200, minimumCount: 16_000)
        #expect(collector.buffers == [expectedCommit, expectedPreview])
        _ = try await session.finish()
    }
}

private final class PreviewSignalCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [[Float]] = []
    var buffers: [[Float]] { lock.withLock { values } }
    func add(_ samples: [Float]) { lock.withLock { values.append(samples) } }
}

private actor ControlledPreviewInference {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var isActive = false
    private(set) var callCount = 0
    func transcribe() async -> String {
        callCount += 1
        isActive = true
        await withCheckedContinuation { continuation = $0 }
        isActive = false
        return "preview atrasado"
    }
    func release() { continuation?.resume(); continuation = nil }
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
