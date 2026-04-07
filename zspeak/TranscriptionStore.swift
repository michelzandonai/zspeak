import Foundation

/// Camada de persistência para histórico de transcrições
@Observable
@MainActor
final class TranscriptionStore {
    var records: [TranscriptionRecord] = []

    private let appSupportDir: URL
    private let audioDir: URL
    private let historyFile: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let defaultBase = base.appendingPathComponent("zspeak", isDirectory: true)
        appSupportDir = defaultBase
        audioDir = defaultBase.appendingPathComponent("audio", isDirectory: true)
        historyFile = defaultBase.appendingPathComponent("history.json")
        try? FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        records = loadRecords()
    }

    init(baseDirectory: URL) {
        appSupportDir = baseDirectory
        audioDir = baseDirectory.appendingPathComponent("audio", isDirectory: true)
        historyFile = baseDirectory.appendingPathComponent("history.json")

        // Criar diretórios se não existirem
        try? FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)

        records = loadRecords()
    }

    // MARK: - API pública

    /// Adiciona um registro de transcrição e salva o áudio como WAV.
    /// Retorna o UUID gerado para que o caller possa linkar correções LLM ao registro original.
    @discardableResult
    func addRecord(
        text: String,
        modelName: String,
        duration: TimeInterval,
        targetAppName: String?,
        samples: [Float]?,
        sourceRecordID: UUID? = nil
    ) -> UUID {
        let id = UUID()
        var audioFileName: String? = nil

        if let samples, !samples.isEmpty {
            let fileName = "\(id.uuidString).wav"
            saveWAV(samples: samples, fileName: fileName)
            audioFileName = fileName
        }

        let record = TranscriptionRecord(
            id: id,
            text: text,
            timestamp: Date(),
            modelName: modelName,
            duration: duration,
            targetAppName: targetAppName,
            audioFileName: audioFileName,
            sourceRecordID: sourceRecordID
        )

        records.insert(record, at: 0)
        saveJSON()
        return id
    }

    /// Remove um registro e seu arquivo de áudio
    func deleteRecord(_ record: TranscriptionRecord) {
        records.removeAll { $0.id == record.id }

        // Deletar WAV se existir
        if let fileName = record.audioFileName {
            let fileURL = audioDir.appendingPathComponent(fileName)
            try? FileManager.default.removeItem(at: fileURL)
        }

        saveJSON()
    }

    /// Retorna URL do arquivo WAV se existir
    func audioURL(for record: TranscriptionRecord) -> URL? {
        guard let fileName = record.audioFileName else { return nil }
        let url = audioDir.appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Persistência JSON

    private func saveJSON() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted

        guard let data = try? encoder.encode(records) else { return }
        try? data.write(to: historyFile, options: .atomic)
    }

    private func loadRecords() -> [TranscriptionRecord] {
        guard FileManager.default.fileExists(atPath: historyFile.path),
              let data = try? Data(contentsOf: historyFile) else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard let loaded = try? decoder.decode([TranscriptionRecord].self, from: data) else {
            return []
        }

        // Ordenar por data, mais recente primeiro
        return loaded.sorted { $0.timestamp > $1.timestamp }
    }

    // MARK: - WAV

    /// Salva samples Float 16kHz mono como arquivo WAV PCM 16-bit
    private func saveWAV(samples: [Float], fileName: String) {
        let url = audioDir.appendingPathComponent(fileName)

        let sampleRate: UInt32 = 16000
        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let bytesPerSample = bitsPerSample / 8
        let dataSize = UInt32(samples.count) * UInt32(bytesPerSample)
        let fileSize = 36 + dataSize

        var header = Data()

        // RIFF header
        header.append(contentsOf: "RIFF".utf8)
        header.append(littleEndian: fileSize)
        header.append(contentsOf: "WAVE".utf8)

        // fmt chunk
        header.append(contentsOf: "fmt ".utf8)
        header.append(littleEndian: UInt32(16))          // chunk size
        header.append(littleEndian: UInt16(1))            // PCM format
        header.append(littleEndian: numChannels)
        header.append(littleEndian: sampleRate)
        header.append(littleEndian: sampleRate * UInt32(numChannels) * UInt32(bytesPerSample)) // byte rate
        header.append(littleEndian: numChannels * bytesPerSample)  // block align
        header.append(littleEndian: bitsPerSample)

        // data chunk
        header.append(contentsOf: "data".utf8)
        header.append(littleEndian: dataSize)

        // Converter Float → Int16
        var pcmData = Data(capacity: Int(dataSize))
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            let int16Value = Int16(clamped * 32767.0)
            pcmData.append(littleEndian: int16Value)
        }

        var fileData = header
        fileData.append(pcmData)

        try? fileData.write(to: url, options: .atomic)
    }
}

// MARK: - Data helper para escrever little-endian

private extension Data {
    mutating func append<T: FixedWidthInteger>(littleEndian value: T) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { self.append(contentsOf: $0) }
    }
}
