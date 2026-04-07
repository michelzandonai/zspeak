import Foundation
import Testing
@testable import zspeak

@Suite("FFmpegTranscoder")
struct FFmpegTranscoderTests {

    // MARK: - Helpers

    private func makeTmpDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    /// Cria WAV PCM 16-bit mono 16kHz válido (1s de silêncio)
    private func createSilentWAV(at url: URL, durationSeconds: Double = 1.0) throws {
        let sampleRate: UInt32 = 16000
        let numSamples = Int(Double(sampleRate) * durationSeconds)

        var data = Data()
        let dataSize = UInt32(numSamples * 2)
        let fileSize = UInt32(36 + dataSize)

        data.append(contentsOf: "RIFF".utf8)
        data.append(contentsOf: withUnsafeBytes(of: fileSize.littleEndian) { Array($0) })
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: sampleRate.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: (sampleRate * 2).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(2).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(16).littleEndian) { Array($0) })
        data.append(contentsOf: "data".utf8)
        data.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Array($0) })
        // Silêncio: 2 bytes zero por sample
        data.append(Data(count: numSamples * 2))

        try data.write(to: url)
    }

    // MARK: - parseDuration / parseOutTimeMicros (funções puras)

    @Test("parseDuration extrai segundos de Duration: HH:MM:SS.xx")
    func parseDurationFormatted() {
        let line = "  Duration: 00:01:30.50, start: 0.000000, bitrate: 128 kb/s"
        let result = FFmpegTranscoder.parseDuration(line)
        #expect(result != nil)
        #expect(abs((result ?? 0) - 90.5) < 0.01)
    }

    @Test("parseDuration extrai horas longas")
    func parseDurationLong() {
        let line = "Duration: 02:30:00.00, ..."
        let result = FFmpegTranscoder.parseDuration(line)
        #expect(result != nil)
        #expect(abs((result ?? 0) - 9000.0) < 0.01)
    }

    @Test("parseDuration retorna nil em texto sem Duration")
    func parseDurationMissing() {
        #expect(FFmpegTranscoder.parseDuration("frame= 100 fps= 25 q=29") == nil)
        #expect(FFmpegTranscoder.parseDuration("") == nil)
    }

    @Test("parseOutTimeMicros extrai out_time_us")
    func parseOutTimeMicrosBasic() {
        let line = "out_time_us=12345678"
        #expect(FFmpegTranscoder.parseOutTimeMicros(line) == 12345678)
    }

    @Test("parseOutTimeMicros lida com texto multilinha")
    func parseOutTimeMicrosMultiline() {
        let text = """
        bitrate=128.0kbits/s
        out_time_us=2500000
        speed=1.5x
        """
        #expect(FFmpegTranscoder.parseOutTimeMicros(text) == 2500000)
    }

    @Test("parseOutTimeMicros retorna nil em texto sem out_time_us")
    func parseOutTimeMicrosMissing() {
        #expect(FFmpegTranscoder.parseOutTimeMicros("Duration: 00:01:00") == nil)
    }

    // MARK: - bundledFFmpegURL / isAvailable

    @Test("bundledFFmpegURL retorna path absoluto se disponível")
    func bundledURLIsAbsolute() {
        guard let url = FFmpegTranscoder.bundledFFmpegURL else {
            // Ambiente sem ffmpeg (CI sem brew): assertiva passa trivialmente
            #expect(!FFmpegTranscoder.isAvailable)
            return
        }
        #expect(url.isFileURL)
        #expect(FileManager.default.isExecutableFile(atPath: url.path))
        #expect(FFmpegTranscoder.isAvailable)
    }

    // MARK: - transcodeToWAV roundtrip (só se ffmpeg disponível)

    @Test("transcodeToWAV converte WAV para WAV 16kHz mono")
    func transcodeWAVRoundtrip() async throws {
        guard FFmpegTranscoder.isAvailable else {
            // Skip: ambiente sem ffmpeg
            return
        }

        let tmp = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Cria WAV 16kHz mono
        let inputURL = tmp.appendingPathComponent("input.wav")
        try createSilentWAV(at: inputURL, durationSeconds: 0.5)

        let outputURL = try await FFmpegTranscoder.shared.transcodeToWAV(inputURL: inputURL)
        defer { try? FileManager.default.removeItem(at: outputURL) }

        // Valida que o arquivo de saída foi criado e tem conteúdo
        #expect(FileManager.default.fileExists(atPath: outputURL.path))
        let attrs = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        let size = attrs[.size] as? Int ?? 0
        #expect(size > 44) // > header WAV
    }

    @Test("binaryNotFound é lançado quando ffmpeg não está disponível em ambiente dev")
    func binaryNotFoundError() async throws {
        // Este teste só faz sentido se o ffmpeg NÃO estiver disponível
        guard !FFmpegTranscoder.isAvailable else {
            return
        }

        let tmp = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let inputURL = tmp.appendingPathComponent("test.wav")
        try createSilentWAV(at: inputURL)

        await #expect(throws: FFmpegTranscoder.FFmpegError.self) {
            _ = try await FFmpegTranscoder.shared.transcodeToWAV(inputURL: inputURL)
        }
    }
}
