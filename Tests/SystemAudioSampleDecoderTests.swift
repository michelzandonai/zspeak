import AVFoundation
import CoreMedia
import Testing
@testable import zspeak

@Suite("SystemAudioSampleDecoder")
struct SystemAudioSampleDecoderTests {
    private func sampleBuffer(samples: [Float], sampleRate: Double = 16_000, channels: AVAudioChannelCount = 1, timestamp: Double = 10) throws -> CMSampleBuffer {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: true))
        var description: CMAudioFormatDescription?
        #expect(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: format.streamDescription, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description) == noErr)
        var block: CMBlockBuffer?
        let byteCount = samples.count * MemoryLayout<Float>.size
        #expect(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: byteCount, flags: 0, blockBufferOut: &block) == noErr)
        let validBlock = try #require(block)
        samples.withUnsafeBytes { bytes in
            #expect(CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: validBlock, offsetIntoDestination: 0, dataLength: byteCount) == noErr)
        }
        var result: CMSampleBuffer?
        let validDescription = try #require(description)
        #expect(CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault, dataBuffer: validBlock, formatDescription: validDescription, sampleCount: samples.count / Int(channels), presentationTimeStamp: CMTime(seconds: timestamp, preferredTimescale: 16_000), packetDescriptions: nil, sampleBufferOut: &result) == noErr)
        return try #require(result)
    }

    @Test("Decodifica PCM do ScreenCaptureKit mantendo timestamp e samples")
    func decodesMonoPCMWithTimestamp() throws {
        let sample = try sampleBuffer(samples: [0.1, 0.2, -0.3, 0])
        let result = try #require(try SystemAudioSampleDecoder().decode(sample))
        #expect(result.startTime == 10)
        #expect(result.samples == [0.1, 0.2, -0.3, 0])
    }

    @Test("Áudio estéreo 48 kHz é convertido para mono 16 kHz")
    func resamplesStereo() throws {
        let samples = (0..<4800).flatMap { _ -> [Float] in [0.2, 0.2] }
        let sample = try sampleBuffer(samples: samples, sampleRate: 48_000, channels: 2)
        let result = try #require(try SystemAudioSampleDecoder().decode(sample))
        #expect(result.samples.count > 1000 && result.samples.count < 1700)
        #expect(result.samples.allSatisfy { $0.isFinite })
        #expect(result.samples.suffix(500).allSatisfy { abs($0 - 0.2) < 0.02 })
    }

    @Test("Configuração solicita áudio mono 16 kHz e exclui sons do próprio zspeak")
    func nativeConfigurationCapturesOnlyRequestedAudio() {
        let configuration = SystemAudioCapture.configuration()
        #expect(configuration.capturesAudio)
        #expect(configuration.sampleRate == 16_000)
        #expect(configuration.channelCount == 1)
        #expect(configuration.excludesCurrentProcessAudio)
    }
}
