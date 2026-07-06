import Foundation
import Testing
@testable import zspeak

@Suite("BenchmarkStore WAV decoding")
struct BenchmarkWAVDecodingTests {

    /// Monta um WAV em memória com chunks arbitrários entre `fmt ` e `data`.
    private func makeWAV(
        samples: [Int16],
        sampleRate: UInt32 = 16_000,
        channels: UInt16 = 1,
        bitsPerSample: UInt16 = 16,
        audioFormat: UInt16 = 1,
        paddingChunk: (id: String, size: Int)? = nil
    ) -> Data {
        var body = Data()

        func append(_ value: UInt32, to data: inout Data) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        func append(_ value: UInt16, to data: inout Data) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }

        // fmt chunk
        body.append(contentsOf: "fmt ".utf8)
        append(UInt32(16), to: &body)
        append(audioFormat, to: &body)
        append(channels, to: &body)
        append(sampleRate, to: &body)
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        append(byteRate, to: &body)
        append(UInt16(channels * (bitsPerSample / 8)), to: &body)
        append(bitsPerSample, to: &body)

        // Chunk extra (ex.: FLLR de padding do CoreAudio)
        if let paddingChunk {
            body.append(contentsOf: paddingChunk.id.utf8)
            append(UInt32(paddingChunk.size), to: &body)
            body.append(Data(repeating: 0xAB, count: paddingChunk.size))
        }

        // data chunk
        var pcm = Data()
        for sample in samples {
            withUnsafeBytes(of: sample.littleEndian) { pcm.append(contentsOf: $0) }
        }
        body.append(contentsOf: "data".utf8)
        append(UInt32(pcm.count), to: &body)
        body.append(pcm)

        var wav = Data()
        wav.append(contentsOf: "RIFF".utf8)
        append(UInt32(4 + body.count), to: &wav)
        wav.append(contentsOf: "WAVE".utf8)
        wav.append(body)
        return wav
    }

    @Test("WAV canônico de 44 bytes decodifica corretamente")
    func decodesCanonicalWAV() throws {
        let source: [Int16] = [0, 16_384, -16_384, 32_767]
        let data = makeWAV(samples: source)

        let samples = try BenchmarkStore.decodeWAV(data)
        #expect(samples.count == 4)
        #expect(samples[0] == 0)
        #expect(abs(samples[1] - 0.5) < 0.001)
        #expect(abs(samples[2] + 0.5) < 0.001)
        #expect(abs(samples[3] - 1.0) < 0.001)
    }

    // Regressão: o parser antigo pulava 44 bytes fixos — um chunk FLLR entre
    // `fmt ` e `data` (padrão em WAVs do CoreAudio) virava "PCM" e alimentava
    // lixo silencioso ao ASR (WER ~100% sem erro reportado).
    @Test("WAV com chunk FLLR de padding decodifica os samples certos")
    func decodesWAVWithPaddingChunk() throws {
        let source: [Int16] = [100, -100, 200, -200]
        let data = makeWAV(samples: source, paddingChunk: (id: "FLLR", size: 4_000))

        let samples = try BenchmarkStore.decodeWAV(data)
        #expect(samples.count == 4)
        #expect(abs(samples[0] - 100.0 / 32_767.0) < 0.0001)
        #expect(abs(samples[3] + 200.0 / 32_767.0) < 0.0001)
    }

    @Test("WAV estéreo é mixado para mono por média")
    func mixesStereoToMono() throws {
        // Frames intercalados L/R: (1000, 3000) → média 2000
        let data = makeWAV(samples: [1_000, 3_000, -1_000, -3_000], channels: 2)

        let samples = try BenchmarkStore.decodeWAV(data)
        #expect(samples.count == 2)
        #expect(abs(samples[0] - 2_000.0 / 32_767.0) < 0.0001)
        #expect(abs(samples[1] + 2_000.0 / 32_767.0) < 0.0001)
    }

    @Test("Sample rate diferente de 16 kHz falha com mensagem clara")
    func rejectsWrongSampleRate() {
        let data = makeWAV(samples: [0, 0], sampleRate: 44_100)
        #expect(throws: BenchmarkError.self) {
            _ = try BenchmarkStore.decodeWAV(data)
        }
    }

    @Test("WAV float32 (formato 3) é rejeitado")
    func rejectsFloatFormat() {
        let data = makeWAV(samples: [0, 0], bitsPerSample: 32, audioFormat: 3)
        #expect(throws: BenchmarkError.self) {
            _ = try BenchmarkStore.decodeWAV(data)
        }
    }

    @Test("Dados truncados sem magic RIFF são rejeitados")
    func rejectsGarbage() {
        #expect(throws: BenchmarkError.self) {
            _ = try BenchmarkStore.decodeWAV(Data(repeating: 0x42, count: 32))
        }
    }

    // Regressão: chunk `fmt ` que declara 16 bytes mas está truncado no fim do
    // arquivo causava index-out-of-range (crash) em vez de invalidWAV.
    @Test("WAV truncado no meio do chunk fmt lança erro em vez de crashar")
    func rejectsTruncatedFmtChunk() {
        var wav = Data()
        wav.append(contentsOf: "RIFF".utf8)
        withUnsafeBytes(of: UInt32(48).littleEndian) { wav.append(contentsOf: $0) }
        wav.append(contentsOf: "WAVE".utf8)
        // Chunk de enchimento para passar do guard mínimo de 44 bytes
        wav.append(contentsOf: "JUNK".utf8)
        withUnsafeBytes(of: UInt32(16).littleEndian) { wav.append(contentsOf: $0) }
        wav.append(Data(repeating: 0, count: 16))
        // fmt declara 16 bytes, mas o arquivo termina 8 bytes depois
        wav.append(contentsOf: "fmt ".utf8)
        withUnsafeBytes(of: UInt32(16).littleEndian) { wav.append(contentsOf: $0) }
        wav.append(Data(repeating: 0, count: 8))

        #expect(throws: BenchmarkError.self) {
            _ = try BenchmarkStore.decodeWAV(wav)
        }
    }
}
