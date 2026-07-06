import AVFoundation
import Testing
@testable import zspeak

@Suite("StreamingResampler")
struct StreamingResamplerTests {

    /// Gera buffers de 512 frames a 48 kHz com uma senoide contínua (fase
    /// preservada entre blocos), simulando o tap real do AVAudioEngine.
    private func makeSineChunks(
        frequency: Double,
        sampleRate: Double,
        chunkFrames: Int,
        chunkCount: Int
    ) -> [AVAudioPCMBuffer] {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else { return [] }

        var buffers: [AVAudioPCMBuffer] = []
        var sampleIndex = 0
        for _ in 0..<chunkCount {
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(chunkFrames)
            ), let channel = buffer.floatChannelData?[0] else { continue }

            for frame in 0..<chunkFrames {
                let t = Double(sampleIndex) / sampleRate
                channel[frame] = Float(sin(2 * .pi * frequency * t)) * 0.5
                sampleIndex += 1
            }
            buffer.frameLength = AVAudioFrameCount(chunkFrames)
            buffers.append(buffer)
        }
        return buffers
    }

    @Test("48 kHz → 16 kHz preserva continuidade entre blocos de 512 frames")
    func resample48kPreservesContinuityAcrossBlocks() throws {
        let resampler = StreamingResampler()
        let chunks = makeSineChunks(
            frequency: 440,
            sampleRate: 48_000,
            chunkFrames: 512,
            chunkCount: 96 // ~1 s de áudio
        )
        #expect(!chunks.isEmpty)

        var output: [Float] = []
        for chunk in chunks {
            output.append(contentsOf: try resampler.process(chunk))
        }

        // Comprimento ≈ 1/3 do input (com folga para o delay do filtro).
        let inputFrames = 512 * chunks.count
        let expected = inputFrames / 3
        #expect(abs(output.count - expected) < 1_600, "output=\(output.count) esperado≈\(expected)")

        // Uma senoide de 440 Hz a 16 kHz tem delta máximo entre amostras
        // consecutivas de ~0,086 (amplitude 0,5). Transientes de borda do
        // resampling stateless por bloco aparecem como saltos muito maiores.
        // Ignora o transiente inicial do filtro (primeiros 128 samples).
        var maxDelta: Float = 0
        let settled = Array(output.dropFirst(128))
        for index in 1..<settled.count {
            maxDelta = max(maxDelta, abs(settled[index] - settled[index - 1]))
        }
        #expect(maxDelta < 0.2, "maxDelta=\(maxDelta) — descontinuidade entre blocos")
    }

    @Test("Passthrough quando o formato já é 16 kHz mono float32")
    func passthroughAt16kMono() throws {
        let resampler = StreamingResampler()
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160),
              let channel = buffer.floatChannelData?[0] else {
            Issue.record("Não foi possível montar o buffer de teste")
            return
        }

        for frame in 0..<160 {
            channel[frame] = Float(frame) / 160
        }
        buffer.frameLength = 160

        let output = try resampler.process(buffer)
        #expect(output.count == 160)
        #expect(output[0] == 0)
        #expect(abs(output[159] - Float(159) / 160) < 0.0001)
    }

    @Test("Estéreo 48 kHz é convertido para mono 16 kHz")
    func stereoIsDownmixedToMono() throws {
        let resampler = StreamingResampler()
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800) else {
            Issue.record("Não foi possível montar o buffer de teste")
            return
        }

        for channelIndex in 0..<2 {
            guard let channel = buffer.floatChannelData?[channelIndex] else { continue }
            for frame in 0..<4_800 {
                channel[frame] = 0.25
            }
        }
        buffer.frameLength = 4_800

        let output = try resampler.process(buffer)
        #expect(!output.isEmpty)
        #expect(output.allSatisfy { $0.isFinite })
    }
}
