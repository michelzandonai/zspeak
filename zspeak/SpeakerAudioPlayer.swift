import Foundation
import AVFoundation
import os

/// Player simples para tocar snippets de identificação de speakers em loop.
/// Mantém apenas um AVAudioPlayer ativo por vez — clicar em outro speaker pausa o anterior.
@MainActor
final class SpeakerAudioPlayer: ObservableObject {

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.zspeak",
        category: "SpeakerAudioPlayer"
    )

    @Published var playingSpeakerId: String?

    private var player: AVAudioPlayer?
    private var tempFileURL: URL?

    /// Toca um snippet em loop. Se já estava tocando outro, pausa o anterior.
    func play(samples: [Float], for speakerId: String, sampleRate: Int = 16000) {
        stop()

        guard !samples.isEmpty else { return }

        // Escreve WAV temporário (16 kHz mono PCM 16-bit)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zspeak-speaker-\(UUID().uuidString).wav")

        do {
            let data = Self.makeWAVData(samples: samples, sampleRate: UInt32(sampleRate))
            try data.write(to: url, options: .atomic)
            tempFileURL = url

            let p = try AVAudioPlayer(contentsOf: url)
            p.numberOfLoops = -1  // loop infinito
            p.prepareToPlay()
            p.play()
            player = p
            playingSpeakerId = speakerId
        } catch {
            Self.logger.error("Falha ao tocar snippet: \(error.localizedDescription, privacy: .public)")
            cleanup()
        }
    }

    func stop() {
        player?.stop()
        cleanup()
    }

    private func cleanup() {
        player = nil
        playingSpeakerId = nil
        if let url = tempFileURL {
            try? FileManager.default.removeItem(at: url)
            tempFileURL = nil
        }
    }

    deinit {
        if let url = tempFileURL {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - WAV encoding

    /// Constrói WAV PCM 16-bit mono a partir de samples Float [-1, 1]
    private static func makeWAVData(samples: [Float], sampleRate: UInt32) -> Data {
        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let bytesPerSample = bitsPerSample / 8
        let dataSize = UInt32(samples.count) * UInt32(bytesPerSample)
        let fileSize = 36 + dataSize

        var data = Data()
        data.append(contentsOf: "RIFF".utf8)
        data.appendLE(fileSize)
        data.append(contentsOf: "WAVE".utf8)

        data.append(contentsOf: "fmt ".utf8)
        data.appendLE(UInt32(16))
        data.appendLE(UInt16(1))  // PCM
        data.appendLE(numChannels)
        data.appendLE(sampleRate)
        data.appendLE(sampleRate * UInt32(numChannels) * UInt32(bytesPerSample))
        data.appendLE(numChannels * bytesPerSample)
        data.appendLE(bitsPerSample)

        data.append(contentsOf: "data".utf8)
        data.appendLE(dataSize)

        var pcm = Data(capacity: Int(dataSize))
        for s in samples {
            let clamped = max(-1.0, min(1.0, s))
            let i = Int16(clamped * 32767.0)
            pcm.appendLE(i)
        }
        data.append(pcm)
        return data
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { self.append(contentsOf: $0) }
    }
}
