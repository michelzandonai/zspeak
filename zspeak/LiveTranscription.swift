import AVFoundation
import FluidAudio
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

    private let transcribePreview: PreviewTranscriber
    private let onUpdate: @Sendable (LiveTranscriptionUpdate) -> Void

    private var samples: [Float] = []
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
                publish(text)
            }
        } catch is CancellationError {
            // Cancelamento esperado ao parar a gravação; o batch final assume.
        } catch {
            // Preview ao vivo é best-effort. A transcrição final continua intacta.
        }

        completePreview()
    }

    private func publish(_ text: String) {
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

    private static func prepareForPreview(_ samples: [Float]) -> [Float] {
        var prepared = samples
        prepared.append(contentsOf: repeatElement(Float.zero, count: trailingPaddingSamples))
        if prepared.count < minimumPreviewSamples {
            prepared.append(contentsOf: repeatElement(Float.zero, count: minimumPreviewSamples - prepared.count))
        }
        return prepared
    }
}

actor FluidLiveTranscriptionSession: LiveTranscriptionSession {
    private let manager: StreamingAsrManager
    private let onUpdate: @Sendable (LiveTranscriptionUpdate) -> Void
    private var updateTask: Task<Void, Never>?
    private var isClosed = false

    init(
        manager: StreamingAsrManager,
        onUpdate: @escaping @Sendable (LiveTranscriptionUpdate) -> Void
    ) {
        self.manager = manager
        self.onUpdate = onUpdate
        self.updateTask = Task { [manager, onUpdate] in
            for await update in await manager.transcriptionUpdates {
                let fullText = await Self.fullTranscript(from: manager)
                guard !fullText.isEmpty else { continue }
                onUpdate(LiveTranscriptionUpdate(
                    text: fullText,
                    isConfirmed: update.isConfirmed,
                    confidence: update.confidence
                ))
            }
        }
    }

    func append(_ samples: [Float]) async {
        guard !isClosed, !samples.isEmpty else { return }
        guard let buffer = Self.makePCMBuffer(samples: samples) else { return }
        await manager.streamAudio(buffer)
    }

    func finish() async throws -> String {
        guard !isClosed else {
            return await Self.fullTranscript(from: manager)
        }

        isClosed = true
        let finalText = try await manager.finish()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        updateTask?.cancel()
        updateTask = nil

        if !finalText.isEmpty {
            onUpdate(LiveTranscriptionUpdate(
                text: finalText,
                isConfirmed: true,
                confidence: 1
            ))
        }
        return finalText
    }

    func cancel() async {
        guard !isClosed else { return }
        isClosed = true
        await manager.cancel()
        updateTask?.cancel()
        updateTask = nil
    }

    private static func fullTranscript(from manager: StreamingAsrManager) async -> String {
        let confirmed = await manager.confirmedTranscript
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let volatile = await manager.volatileTranscript
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return [confirmed, volatile]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func makePCMBuffer(samples: [Float]) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ), let channel = buffer.floatChannelData?[0] else {
            return nil
        }

        samples.withUnsafeBufferPointer { pointer in
            channel.update(from: pointer.baseAddress!, count: samples.count)
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        return buffer
    }
}

extension StreamingAsrConfig {
    /// Configuração voltada para ditado ao vivo: prioriza feedback rápido.
    static let zspeakLive = StreamingAsrConfig(
        chunkSeconds: 1.25,
        hypothesisChunkSeconds: 0.6,
        leftContextSeconds: 1.0,
        rightContextSeconds: 0.25,
        minContextForConfirmation: 1.25,
        confirmationThreshold: 0.62
    )
}
