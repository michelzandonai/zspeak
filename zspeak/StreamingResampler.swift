import AVFoundation

enum StreamingResamplerError: LocalizedError {
    case converterUnavailable
    case conversionFailed

    var errorDescription: String? {
        switch self {
        case .converterUnavailable:
            return "Não foi possível criar o conversor de sample rate"
        case .conversionFailed:
            return "Falha na conversão de sample rate"
        }
    }
}

/// Resampler streaming para o tap de captura: mantém UM `AVAudioConverter`
/// vivo durante toda a sessão do engine, preservando o estado interno do
/// filtro de decimação entre callbacks.
///
/// Motivação: o `AudioConverter` do FluidAudio é stateless por chamada — cria
/// um conversor novo e finaliza com `.endOfStream` a cada buffer. Com tap de
/// 512 frames (~10,7 ms @ 48 kHz), isso "prima" e "flusha" o filtro ~94×/s,
/// injetando transientes de borda periódicos no áudio 16 kHz entregue ao
/// Parakeet (ruído espectral que degrada WER) além de pagar alocação e
/// negociação de formato por callback.
final class StreamingResampler: @unchecked Sendable {
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private let targetSampleRate: Double

    init(targetSampleRate: Double = 16_000) {
        self.targetSampleRate = targetSampleRate
    }

    /// Converte um buffer do tap para 16 kHz mono float32.
    /// Seguro para chamar da render thread — sem I/O, lock apenas contra
    /// `reset()` (que roda fora do hotpath).
    func process(_ buffer: AVAudioPCMBuffer) throws -> [Float] {
        lock.lock()
        defer { lock.unlock() }

        let format = buffer.format

        // Passthrough: hardware já entrega o formato alvo.
        if format.sampleRate == targetSampleRate,
           format.channelCount == 1,
           format.commonFormat == .pcmFormatFloat32,
           let channel = buffer.floatChannelData?[0] {
            return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        }

        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw StreamingResamplerError.converterUnavailable
        }

        if converter == nil || inputFormat != format {
            guard let newConverter = AVAudioConverter(from: format, to: outputFormat) else {
                throw StreamingResamplerError.converterUnavailable
            }
            newConverter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
            converter = newConverter
            inputFormat = format
        }

        guard let converter else {
            throw StreamingResamplerError.converterUnavailable
        }

        let ratio = targetSampleRate / format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw StreamingResamplerError.conversionFailed
        }

        // Entrega o buffer uma única vez; `.noDataNow` sinaliza streaming —
        // o conversor devolve o que tem e retém o estado do filtro para o
        // próximo callback (sem flush de fim de stream).
        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: outBuffer, error: &conversionError) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        if status == .error {
            throw conversionError ?? StreamingResamplerError.conversionFailed
        }

        guard let channel = outBuffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(outBuffer.frameLength)))
    }

    /// Descarta o estado do filtro. Chamado quando o engine é desmontado para
    /// que a próxima sessão não herde a cauda da anterior.
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        converter?.reset()
        converter = nil
        inputFormat = nil
    }
}
