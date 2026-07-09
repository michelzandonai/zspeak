import Foundation

struct LiveTranscriptionUpdate: Sendable, Equatable {
    let text: String
    let isConfirmed: Bool
    let confidence: Float
}

protocol LiveTranscriptionSession: Sendable {
    func append(_ samples: [Float]) async
    func finish() async throws -> String
    func cancel() async
}

actor CumulativeLiveTranscriptionSession: LiveTranscriptionSession {
    typealias PreviewTranscriber = @Sendable ([Float]) async throws -> String

    private static let sampleRate = 16_000
    private static let minimumPreviewSamples = sampleRate
    private static let previewStrideSamples = 12_000
    private static let trailingPaddingSamples = 3_200
    /// Janela máxima re-transcrita por preview. Acima disso, o trecho mais
    /// antigo é "commitado" (transcrito uma última vez e congelado como texto
    /// confirmado) e sai da janela. Sem o commit, cada preview re-transcrevia
    /// a sessão INTEIRA desde t=0 — custo quadrático que, em ditados longos,
    /// fazia o preview atrasar segundos e competir com o batch final no ANE.
    private static let commitWindowSamples = 12 * sampleRate
    /// Início da região onde procuramos o ponto de corte (mais silencioso).
    private static let commitSearchStartSamples = 8 * sampleRate
    /// Tamanho da janela de energia usada para achar o corte (240 ms).
    private static let commitCutWindowSamples = Int(0.240 * Double(sampleRate))

    private let transcribePreview: PreviewTranscriber
    private let onUpdate: @Sendable (LiveTranscriptionUpdate) -> Void

    /// Janela corrente de áudio (o prefixo já commitado é descartado).
    private var samples: [Float] = []
    /// Texto dos trechos já commitados — prefixo estável do preview.
    private var confirmedText = ""
    private var lastRequestedSampleCount = 0
    private var lastPublishedText = ""
    private var isProcessing = false
    private var pendingPreview = false
    private var isClosed = false
    private var processingTask: Task<Void, Never>?

    init(
        transcribePreview: @escaping PreviewTranscriber,
        onUpdate: @escaping @Sendable (LiveTranscriptionUpdate) -> Void
    ) {
        self.transcribePreview = transcribePreview
        self.onUpdate = onUpdate
    }

    func append(_ newSamples: [Float]) async {
        guard !isClosed, !newSamples.isEmpty else { return }
        samples.append(contentsOf: newSamples)
        requestPreviewIfNeeded(force: false)
    }

    func finish() async throws -> String {
        isClosed = true
        pendingPreview = false
        processingTask?.cancel()
        processingTask = nil
        return lastPublishedText
    }

    func cancel() async {
        isClosed = true
        pendingPreview = false
        processingTask?.cancel()
        processingTask = nil
    }

    private func requestPreviewIfNeeded(force: Bool) {
        guard !isClosed else { return }
        guard samples.count >= Self.minimumPreviewSamples else { return }

        let hasEnoughNewAudio = samples.count - lastRequestedSampleCount >= Self.previewStrideSamples
        guard force || hasEnoughNewAudio else { return }

        if isProcessing {
            pendingPreview = true
            return
        }

        isProcessing = true

        // Janela estourou: commita o trecho mais antigo (até o ponto mais
        // silencioso, para não cortar palavra ao meio) e o remove da janela.
        // O preview seguinte cobre o restante via `pendingPreview`.
        if samples.count >= Self.commitWindowSamples {
            let cut = Self.commitCutIndex(
                samples: samples,
                searchStart: Self.commitSearchStartSamples,
                windowSize: Self.commitCutWindowSamples
            )
            let commitChunk = Array(samples[0..<cut])
            samples.removeFirst(cut)
            lastRequestedSampleCount = samples.count
            pendingPreview = true
            processingTask = Task { [weak self] in
                await self?.processCommit(commitChunk)
            }
            return
        }

        lastRequestedSampleCount = samples.count
        let snapshot = samples
        processingTask = Task { [weak self] in
            await self?.processPreview(snapshot)
        }
    }

    private func processPreview(_ snapshot: [Float]) async {
        do {
            let text = try await transcribePreview(Self.prepareForPreview(snapshot))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !Task.isCancelled {
                publish(windowText: text)
            }
        } catch is CancellationError {
            // Cancelamento esperado ao parar a gravação; o batch final assume.
        } catch {
            // Preview ao vivo é best-effort. A transcrição final continua intacta.
        }

        completePreview()
    }

    /// Transcreve o trecho que saiu da janela e o congela em `confirmedText`.
    private func processCommit(_ chunk: [Float]) async {
        do {
            let text = try await transcribePreview(Self.prepareForPreview(chunk))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !Task.isCancelled, !text.isEmpty {
                // Só acumula — publicar aqui encolheria o texto na tela (a
                // janela corrente sumiria até o próximo preview), causando o
                // efeito "apaga tudo e reescreve" no overlay. O preview
                // pendente publica confirmado + janela de uma vez.
                confirmedText = Self.joined(confirmedText, text)
            }
        } catch is CancellationError {
            // Sem problema: o batch final cobre o áudio completo.
        } catch {
            // Best-effort — o trecho some do preview mas não da transcrição final.
        }

        completePreview()
    }

    private func publish(windowText: String) {
        let text = Self.joined(confirmedText, windowText)
        guard !isClosed, !text.isEmpty, text != lastPublishedText else { return }
        lastPublishedText = text
        onUpdate(LiveTranscriptionUpdate(
            text: text,
            isConfirmed: false,
            confidence: 1
        ))
    }

    private func completePreview() {
        isProcessing = false
        processingTask = nil

        guard pendingPreview, !isClosed else {
            pendingPreview = false
            return
        }

        pendingPreview = false
        requestPreviewIfNeeded(force: true)
    }

    private static func joined(_ lhs: String, _ rhs: String) -> String {
        [lhs, rhs].filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func prepareForPreview(_ samples: [Float]) -> [Float] {
        var prepared = samples
        prepared.append(contentsOf: repeatElement(Float.zero, count: trailingPaddingSamples))
        if prepared.count < minimumPreviewSamples {
            prepared.append(contentsOf: repeatElement(Float.zero, count: minimumPreviewSamples - prepared.count))
        }
        return prepared
    }

    /// Encontra o índice de corte para o commit: o centro da janela de menor
    /// energia RMS entre `searchStart` e o fim do buffer. Cortar no trecho
    /// mais silencioso minimiza a chance de dividir uma palavra entre o texto
    /// confirmado e a janela seguinte.
    static func commitCutIndex(samples: [Float], searchStart: Int, windowSize: Int) -> Int {
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
            for sample in samples[index..<(index + window)] {
                sum += sample * sample
            }
            if sum < quietestEnergy {
                quietestEnergy = sum
                quietestStart = index
            }
            index += hop
        }

        return quietestStart + window / 2
    }
}

// Nota: a implementação alternativa `FluidLiveTranscriptionSession` (baseada no
// StreamingAsrManager do FluidAudio) foi removida por nunca ter sido adotada —
// o caminho em produção é o CumulativeLiveTranscriptionSession acima. Histórico
// completo no git, caso a abordagem de streaming nativo volte à mesa.
