import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit
import os

enum SystemAudioCaptureError: LocalizedError {
    case permissionRequired
    case displayUnavailable
    case captureFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionRequired:
            return "Autorize zspeak em Ajustes do Sistema → Privacidade e Segurança → Gravação de tela e áudio do sistema. Depois tente gravar novamente."
        case .displayUnavailable:
            return "Nenhuma tela disponível para iniciar a captura de áudio do computador."
        case .captureFailed(let message):
            return "Não foi possível capturar o áudio do computador: \(message)"
        }
    }
}

protocol SystemAudioCapturing: Actor {
    func prepare() async throws
    func start(onChunk: @escaping @Sendable (TimestampedAudioChunk) -> Void) async throws
    func stop() async
    func isRunning() -> Bool
}

/// Captura somente a saída de áudio. Nenhum output de vídeo é registrado.
actor SystemAudioCapture: SystemAudioCapturing {
    private var stream: SCStream?
    private var receiver: SystemAudioStreamReceiver?
    private let callbackQueue = DispatchQueue(label: "com.zspeak.system-audio")

    func prepare() async throws {
        try Task.checkCancellation()
        if !CGPreflightScreenCaptureAccess() {
            _ = await MainActor.run { CGRequestScreenCaptureAccess() }
            guard CGPreflightScreenCaptureAccess() else { throw SystemAudioCaptureError.permissionRequired }
        }
        try Task.checkCancellation()
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            if !CGPreflightScreenCaptureAccess() { throw SystemAudioCaptureError.permissionRequired }
            throw SystemAudioCaptureError.captureFailed(error.localizedDescription)
        }
        try Task.checkCancellation()
        guard let display = content.displays.first else { throw SystemAudioCaptureError.displayUnavailable }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let configuration = Self.configuration()
        let receiver = SystemAudioStreamReceiver()
        self.receiver = receiver
        stream = SCStream(filter: filter, configuration: configuration, delegate: receiver)
    }

    static func configuration() -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.sampleRate = 16_000
        configuration.channelCount = 1
        configuration.excludesCurrentProcessAudio = true
        // ScreenCaptureKit exige um filtro de tela mesmo para áudio. Reduzimos
        // o trabalho visual e não registramos nem guardamos frames de vídeo.
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.showsCursor = false
        return configuration
    }

    func start(onChunk: @escaping @Sendable (TimestampedAudioChunk) -> Void) async throws {
        guard let stream, let receiver else { throw SystemAudioCaptureError.captureFailed("Captura não preparada.") }
        receiver.setHandler(onChunk)
        do {
            try stream.addStreamOutput(receiver, type: .audio, sampleHandlerQueue: callbackQueue)
            receiver.running.set(true)
            try await stream.startCapture()
            try Task.checkCancellation()
        } catch {
            await stop()
            if error is CancellationError { throw error }
            throw SystemAudioCaptureError.captureFailed(error.localizedDescription)
        }
    }

    func stop() async {
        let currentStream = stream
        let currentReceiver = receiver
        stream = nil
        receiver = nil
        try? await currentStream?.stopCapture()
        // Drena callbacks já enfileirados antes de fechar a mistura final.
        await withCheckedContinuation { continuation in
            callbackQueue.async { continuation.resume() }
        }
        currentReceiver?.running.set(false)
        currentReceiver?.setHandler(nil)
    }

    func isRunning() -> Bool { receiver?.running.current == true }
}

/// Mantém o CMSampleBuffer na fila nativa; só arrays Sendable saem dela.
private final class SystemAudioStreamReceiver: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let running = AtomicBool()
    private let decoder = SystemAudioSampleDecoder()
    private let lock = NSLock()
    private var handler: (@Sendable (TimestampedAudioChunk) -> Void)?
    private let logger = Logger(subsystem: "com.zspeak", category: "SystemAudioCapture")

    func setHandler(_ handler: (@Sendable (TimestampedAudioChunk) -> Void)?) {
        lock.withLock { self.handler = handler }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, running.current else { return }
        do {
            if let chunk = try decoder.decode(sampleBuffer) {
                let callback = lock.withLock { handler }
                callback?(chunk)
            }
        } catch {
            running.set(false)
            logger.error("Falha ao decodificar áudio do sistema: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        running.set(false)
        logger.error("Captura de áudio do sistema interrompida: \(error.localizedDescription, privacy: .public)")
    }
}

final class SystemAudioSampleDecoder {
    private let resampler = StreamingResampler()

    func decode(_ sampleBuffer: CMSampleBuffer) throws -> TimestampedAudioChunk? {
        guard CMSampleBufferDataIsReady(sampleBuffer), CMSampleBufferGetNumSamples(sampleBuffer) > 0,
              let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              CMFormatDescriptionGetMediaType(description) == kCMMediaType_Audio else { return nil }
        guard let basicFormat = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              basicFormat.pointee.mFormatID == kAudioFormatLinearPCM,
              basicFormat.pointee.mSampleRate > 0, basicFormat.pointee.mChannelsPerFrame > 0 else {
            throw SystemAudioCaptureError.captureFailed("Formato PCM inválido.")
        }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        var requiredSize = 0
        let queryStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: &requiredSize, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0, blockBufferOut: nil
        )
        guard queryStatus == noErr, requiredSize >= MemoryLayout<AudioBufferList>.size else {
            throw SystemAudioCaptureError.captureFailed("Não foi possível obter o tamanho do buffer (\(queryStatus)).")
        }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: requiredSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        let buffers = storage.bindMemory(to: AudioBufferList.self, capacity: 1)
        var retainedBlock: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil,
            bufferListOut: buffers,
            bufferListSize: requiredSize,
            blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0, blockBufferOut: &retainedBlock
        )
        guard status == noErr,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: UnsafePointer(buffers), deallocator: nil) else {
            throw SystemAudioCaptureError.captureFailed("Buffer de áudio inválido (\(status)).")
        }
        let samples = try withExtendedLifetime(retainedBlock) { try resampler.process(buffer) }
        guard !samples.isEmpty else { return nil }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let seconds = CMTimeGetSeconds(timestamp)
        let start = timestamp.isValid && seconds.isFinite
            ? seconds : audioHostTime() - Double(samples.count) / AudioTimelineMixer.sampleRate
        return TimestampedAudioChunk(startTime: start, samples: samples)
    }
}
