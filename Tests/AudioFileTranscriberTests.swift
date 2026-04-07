import Foundation
import Testing
@testable import zspeak

/// Helper para coletar fases do callback @Sendable
@MainActor
private final class PhasesBox {
    var values: [String] = []
    func append(_ phase: String) { values.append(phase) }
}

@Suite("AudioFileTranscriber")
@MainActor
struct AudioFileTranscriberTests {

    // MARK: - Helpers

    private func makeTmpDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    /// Cria um WAV PCM 16-bit mono 16kHz válido com N samples de seno simples
    private func createTestWAV(at url: URL, durationSeconds: Double = 1.0) throws {
        let sampleRate: UInt32 = 16000
        let numSamples = Int(Double(sampleRate) * durationSeconds)

        // Samples: seno de 440 Hz
        var samples: [Int16] = []
        samples.reserveCapacity(numSamples)
        for i in 0..<numSamples {
            let t = Double(i) / Double(sampleRate)
            let value = sin(2.0 * .pi * 440.0 * t) * 0.3
            samples.append(Int16(value * 32767.0))
        }

        var data = Data()
        let dataSize = UInt32(samples.count * 2)
        let fileSize = UInt32(36 + dataSize)

        // RIFF header
        data.append(contentsOf: "RIFF".utf8)
        data.append(contentsOf: withUnsafeBytes(of: fileSize.littleEndian) { Array($0) })
        data.append(contentsOf: "WAVE".utf8)

        // fmt chunk
        data.append(contentsOf: "fmt ".utf8)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: sampleRate.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: (sampleRate * 2).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(2).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(16).littleEndian) { Array($0) })

        // data chunk
        data.append(contentsOf: "data".utf8)
        data.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Array($0) })
        for sample in samples {
            data.append(contentsOf: withUnsafeBytes(of: sample.littleEndian) { Array($0) })
        }

        try data.write(to: url)
    }

    // MARK: - supportedExtensions / isSupported

    @Test("Formatos nativos estão em supportedNativeExtensions")
    func nativeFormatsDefined() {
        let expected: Set<String> = ["wav", "mp3", "m4a", "aac", "flac", "aif", "aiff", "caf"]
        #expect(AudioFileTranscriber.supportedNativeExtensions == expected)
    }

    @Test("Formatos via ffmpeg estão em ffmpegExtensions")
    func ffmpegFormatsDefined() {
        #expect(AudioFileTranscriber.ffmpegExtensions.contains("opus"))
        #expect(AudioFileTranscriber.ffmpegExtensions.contains("ogg"))
        #expect(AudioFileTranscriber.ffmpegExtensions.contains("wma"))
        #expect(AudioFileTranscriber.ffmpegExtensions.contains("amr"))
    }

    @Test("supportedExtensions é união dos dois sets")
    func supportedExtensionsIsUnion() {
        let native = AudioFileTranscriber.supportedNativeExtensions
        let ffmpeg = AudioFileTranscriber.ffmpegExtensions
        let combined = AudioFileTranscriber.supportedExtensions
        #expect(combined == native.union(ffmpeg))
        #expect(combined.contains("wav"))
        #expect(combined.contains("opus"))
        #expect(!combined.contains("xyz"))
    }

    @Test("isSupported detecta formatos case-insensitive")
    func isSupportedCaseInsensitive() {
        #expect(AudioFileTranscriber.isSupported(url: URL(fileURLWithPath: "/tmp/a.WAV")))
        #expect(AudioFileTranscriber.isSupported(url: URL(fileURLWithPath: "/tmp/b.Mp3")))
        #expect(AudioFileTranscriber.isSupported(url: URL(fileURLWithPath: "/tmp/c.OPUS")))
        #expect(!AudioFileTranscriber.isSupported(url: URL(fileURLWithPath: "/tmp/d.xyz")))
    }

    // MARK: - makeChunks

    @Test("makeChunks retorna chunk único para áudio curto (<60s)")
    func chunksShortAudio() {
        // 30s a 16kHz = 480000 samples
        let samples = Array(repeating: Float(0.0), count: 480000)
        let chunks = AudioFileTranscriber.makeChunks(samples: samples)
        #expect(chunks.count == 1)
        #expect(chunks[0].count == 480000)
    }

    @Test("makeChunks divide áudio longo em chunks de 30s")
    func chunksLongAudio() {
        // 90s a 16kHz = 1440000 samples → deve dar 3 chunks de 30s
        let samples = Array(repeating: Float(0.5), count: 1440000)
        let chunks = AudioFileTranscriber.makeChunks(samples: samples)
        #expect(chunks.count == 3)
        #expect(chunks[0].count == 480000) // 30s
        #expect(chunks[1].count == 480000) // 30s
        #expect(chunks[2].count == 480000) // 30s
    }

    @Test("makeChunks último chunk pode ser parcial")
    func chunksLastPartial() {
        // 70s a 16kHz = 1120000 samples → 2 chunks (30s + 30s + 10s sobrando como chunk 3)
        let samples = Array(repeating: Float(0.0), count: 1120000)
        let chunks = AudioFileTranscriber.makeChunks(samples: samples)
        #expect(chunks.count == 3)
        #expect(chunks[0].count == 480000) // 30s
        #expect(chunks[1].count == 480000) // 30s
        #expect(chunks[2].count == 160000) // 10s parcial
    }

    @Test("makeChunks total samples preservado")
    func chunksPreserveSamples() {
        let samples = (0..<1500000).map { Float($0) }
        let chunks = AudioFileTranscriber.makeChunks(samples: samples)
        let total = chunks.reduce(0) { $0 + $1.count }
        #expect(total == samples.count)
    }

    // MARK: - formatTimestamp

    @Test("formatTimestamp < 1 hora retorna MM:SS")
    func formatTimestampShort() {
        #expect(AudioFileTranscriber.formatTimestamp(0) == "[00:00]")
        #expect(AudioFileTranscriber.formatTimestamp(65) == "[01:05]")
        #expect(AudioFileTranscriber.formatTimestamp(599) == "[09:59]")
    }

    @Test("formatTimestamp >= 1 hora retorna HH:MM:SS")
    func formatTimestampLong() {
        #expect(AudioFileTranscriber.formatTimestamp(3600) == "[01:00:00]")
        #expect(AudioFileTranscriber.formatTimestamp(3725) == "[01:02:05]")
    }

    // MARK: - diarizingSubphase

    @Test("diarizingSubphase retorna sub-fases conforme % do tempo")
    func diarizingSubphasePhases() {
        let est: TimeInterval = 100
        #expect(AudioFileTranscriber.diarizingSubphase(elapsed: 0, estimated: est) == "Analisando segmentos de voz...")
        #expect(AudioFileTranscriber.diarizingSubphase(elapsed: 50, estimated: est) == "Extraindo características vocais...")
        #expect(AudioFileTranscriber.diarizingSubphase(elapsed: 90, estimated: est) == "Agrupando interlocutores...")
        #expect(AudioFileTranscriber.diarizingSubphase(elapsed: 110, estimated: est) == "Finalizando...")
    }

    @Test("diarizingSubphase com estimated 0 retorna fallback")
    func diarizingSubphaseZeroEstimated() {
        #expect(AudioFileTranscriber.diarizingSubphase(elapsed: 5, estimated: 0) == "Identificando interlocutores...")
    }

    // MARK: - Erros

    @Test("unsupportedFormat é lançado para extensão inválida")
    func unsupportedFormatThrows() async throws {
        let tmp = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let xyzURL = tmp.appendingPathComponent("fake.xyz")
        try "not audio".write(to: xyzURL, atomically: true, encoding: .utf8)

        let transcriber = AudioFileTranscriber(
            transcribe: { _ in "should not be called" },
            diarizer: nil
        )

        await #expect(throws: AudioFileTranscriber.TranscriberError.self) {
            _ = try await transcriber.transcribe(url: xyzURL, mode: .plain) { _ in }
        }
    }

    @Test("emptyAudio é lançado para WAV vazio/muito curto")
    func emptyAudioThrows() async throws {
        let tmp = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let wavURL = tmp.appendingPathComponent("tiny.wav")
        // WAV com apenas 10ms de áudio (160 samples < 8000)
        try createTestWAV(at: wavURL, durationSeconds: 0.01)

        let transcriber = AudioFileTranscriber(
            transcribe: { _ in "should not be called" },
            diarizer: nil
        )

        await #expect(throws: AudioFileTranscriber.TranscriberError.self) {
            _ = try await transcriber.transcribe(url: wavURL, mode: .plain) { _ in }
        }
    }

    @Test("diarizerUnavailable é lançado se modo meeting sem diarizer")
    func meetingWithoutDiarizerThrows() async throws {
        let tmp = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let wavURL = tmp.appendingPathComponent("test.wav")
        try createTestWAV(at: wavURL, durationSeconds: 1.0)

        let transcriber = AudioFileTranscriber(
            transcribe: { _ in "fake text" },
            diarizer: nil
        )

        await #expect(throws: AudioFileTranscriber.TranscriberError.self) {
            _ = try await transcriber.transcribe(url: wavURL, mode: .meeting) { _ in }
        }
    }

    // MARK: - Pipeline plain com WAV real

    @Test("Pipeline plain lê WAV e chama closure de transcribe")
    func plainPipelineWithWAV() async throws {
        let tmp = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let wavURL = tmp.appendingPathComponent("voice.wav")
        try createTestWAV(at: wavURL, durationSeconds: 1.0)

        var transcribeCalled = false
        var receivedSamples: [Float] = []

        let transcriber = AudioFileTranscriber(
            transcribe: { samples in
                transcribeCalled = true
                receivedSamples = samples
                return "mocked transcription"
            },
            diarizer: nil
        )

        let phasesBox = PhasesBox()
        let result = try await transcriber.transcribe(url: wavURL, mode: .plain) { phase in
            switch phase {
            case .transcoding: phasesBox.append("transcoding")
            case .loadingSamples: phasesBox.append("loading")
            case .diarizing: phasesBox.append("diarizing")
            case .transcribing: phasesBox.append("transcribing")
            }
        }
        let phasesObserved = phasesBox.values

        #expect(transcribeCalled)
        #expect(receivedSamples.count > 8000)  // pelo menos 0.5s a 16kHz
        #expect(result.text == "mocked transcription")
        #expect(result.segments == nil)
        #expect(result.sourceFileName == "voice.wav")
        #expect(result.durationSeconds > 0.5)
        #expect(result.samples.count == receivedSamples.count)
        #expect(phasesObserved.contains("loading"))
        #expect(phasesObserved.contains("transcribing"))
        // WAV é nativo, não deve ter transcoded
        #expect(!phasesObserved.contains("transcoding"))
    }
}
