import Foundation
import os.log

/// Camada de persistência para histórico de transcrições
@Observable
@MainActor
final class TranscriptionStore {
    var records: [TranscriptionRecord] = [] {
        didSet { invalidateLookupCache() }
    }

    /// Cache do lookup O(1) por ID. Invalidado automaticamente quando `records` muda.
    @ObservationIgnored
    private var _cachedRecordsByID: [UUID: TranscriptionRecord]?

    /// Lookup O(1) por ID. Cacheado; rebuild sob demanda após mutação de `records`.
    var recordsByID: [UUID: TranscriptionRecord] {
        if let cached = _cachedRecordsByID { return cached }
        let built = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        _cachedRecordsByID = built
        return built
    }

    private func invalidateLookupCache() {
        _cachedRecordsByID = nil
    }

    private let appSupportDir: URL
    private let audioDir: URL
    private let historyFile: URL

    /// Fila serial dedicada a encode + I/O. Fora da main thread.
    /// Saves são enfileirados (ordem preservada); nunca corrompem por concorrência.
    @ObservationIgnored
    private let persistQueue: DispatchQueue

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let defaultBase = base.appendingPathComponent("zspeak", isDirectory: true)
        appSupportDir = defaultBase
        audioDir = defaultBase.appendingPathComponent("audio", isDirectory: true)
        historyFile = defaultBase.appendingPathComponent("history.json")
        persistQueue = StorePersistQueue.shared(forFileAt: historyFile)
        try? FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        records = loadRecords()
    }

    init(baseDirectory: URL) {
        appSupportDir = baseDirectory
        audioDir = baseDirectory.appendingPathComponent("audio", isDirectory: true)
        historyFile = baseDirectory.appendingPathComponent("history.json")
        persistQueue = StorePersistQueue.shared(forFileAt: historyFile)

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
            // WAV encoding + write fora da main thread, na fila serial do store.
            enqueueSaveWAV(samples: samples, fileName: fileName)
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

    /// Atualiza o map de nomes de speakers de um registro existente
    func updateSpeakerNames(recordID: UUID, names: [String: String]) {
        guard let idx = records.firstIndex(where: { $0.id == recordID }) else { return }
        records[idx].speakerNames = names
        saveJSON()
    }

    /// Remove um registro e seu arquivo de áudio.
    /// O `removeItem` é um syscall rápido — mantemos síncrono para que callers que
    /// checam `fileExists` logo em seguida vejam o arquivo removido.
    func deleteRecord(_ record: TranscriptionRecord) {
        records.removeAll { $0.id == record.id }

        if let fileName = record.audioFileName {
            let fileURL = audioDir.appendingPathComponent(fileName)
            try? FileManager.default.removeItem(at: fileURL)
        }

        saveJSON()
    }

    /// Retorna URL do arquivo WAV se existir.
    ///
    /// Drena writes pendentes antes de consultar, para que um `audioURL` chamado
    /// logo após `addRecord(samples:)` sempre reflita o arquivo já no disco.
    func audioURL(for record: TranscriptionRecord) -> URL? {
        guard let fileName = record.audioFileName else { return nil }
        persistQueue.sync { }
        let url = audioDir.appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Persistência JSON

    /// Envelope versionado em disco: `{ schemaVersion: 1, records: [...] }`.
    /// Permite migração de schema sem corromper JSON silenciosamente.
    fileprivate struct Envelope: Codable {
        let schemaVersion: Int
        let records: [TranscriptionRecord]
    }

    /// Captura snapshot no main e enfileira encode+write no background.
    /// Escritas em ordem de chamada; a última vence no disco.
    private func saveJSON() {
        let snapshot = records
        let file = historyFile

        persistQueue.async {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

            let envelope = Envelope(
                schemaVersion: TranscriptionStoreSchema.currentVersion,
                records: snapshot
            )

            guard let data = try? encoder.encode(envelope) else { return }
            try? data.write(to: file, options: .atomic)
        }
    }

    private func loadRecords() -> [TranscriptionRecord] {
        // Drena writes pendentes do mesmo queue antes de reler (relevante em testes
        // que criam múltiplas instâncias no mesmo diretório).
        persistQueue.sync { }

        guard FileManager.default.fileExists(atPath: historyFile.path) else {
            return []
        }

        let data: Data
        do {
            data = try Data(contentsOf: historyFile)
        } catch {
            StoreLog.shared.log("TranscriptionStore: falha ao ler \(historyFile.lastPathComponent): \(error)")
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // Tenta formato novo (envelope com schemaVersion).
        if let envelope = try? decoder.decode(Envelope.self, from: data) {
            if envelope.schemaVersion == TranscriptionStoreSchema.currentVersion {
                return envelope.records.sorted { $0.timestamp > $1.timestamp }
            }
            StoreLog.shared.log("TranscriptionStore: schemaVersion desconhecida \(envelope.schemaVersion); fazendo backup e começando vazio")
            StoreLog.shared.backup(fileURL: historyFile)
            return []
        }

        // Formato legado (array direto) — migra para v1 transparentemente.
        if let legacy = try? decoder.decode([TranscriptionRecord].self, from: data) {
            return legacy.sorted { $0.timestamp > $1.timestamp }
        }

        // JSON corrompido: faz backup antes de silenciar.
        StoreLog.shared.log("TranscriptionStore: JSON malformado em \(historyFile.lastPathComponent); fazendo backup")
        StoreLog.shared.backup(fileURL: historyFile)
        return []
    }

    // MARK: - WAV

    /// Enfileira encode+write de WAV na fila de persistência (fora da main thread).
    private func enqueueSaveWAV(samples: [Float], fileName: String) {
        let url = audioDir.appendingPathComponent(fileName)
        persistQueue.async {
            let data = encodeWAV(samples: samples)
            try? data.write(to: url, options: .atomic)
        }
    }
}

// MARK: - Constants / schema

/// Versão corrente do schema persistido de `TranscriptionStore`.
/// Vive fora da classe @MainActor para ser Sendable e acessível em closures detached.
enum TranscriptionStoreSchema {
    static let currentVersion = 1
}

/// Codifica samples Float 16kHz mono como WAV PCM 16-bit. Pure, safe off-main.
fileprivate func encodeWAV(samples: [Float]) -> Data {
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
    return fileData
}

// MARK: - Registry de filas de persistência (uma por path)

/// Garante que duas instâncias de store apontando para o mesmo arquivo compartilhem
/// a mesma fila serial. Assim, writes assíncronos de uma instância são drenados
/// quando outra instância (ex: test que recarrega do mesmo diretório) faz `load`.
///
/// Registry thread-safe via lock interno; o lookup é O(1) e só é exercitado em
/// init/load — não no hot path de mutação.
enum StorePersistQueue {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var queues: [String: DispatchQueue] = [:]

    static func shared(forFileAt url: URL) -> DispatchQueue {
        let key = url.standardizedFileURL.path
        lock.lock()
        defer { lock.unlock() }
        if let existing = queues[key] {
            return existing
        }
        let q = DispatchQueue(label: "com.zspeak.Store.persist[\(key.hashValue)]", qos: .utility)
        queues[key] = q
        return q
    }
}

// MARK: - Logger compartilhado para falhas de persistência dos stores

/// Logger thread-safe para falhas de persistência. Reutilizado por todos os stores.
final class StoreLog: @unchecked Sendable {
    static let shared = StoreLog()
    private let logger = Logger(subsystem: "com.zspeak", category: "Store")

    func log(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }

    /// Renomeia `fileURL` para `<nome>.<ext>.bak-<timestamp>` preservando o arquivo
    /// corrompido antes de qualquer sobrescrita. Falhas de backup não propagam.
    func backup(fileURL: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else { return }
        let ts = Int(Date().timeIntervalSince1970)
        let backupURL = fileURL.appendingPathExtension("bak-\(ts)")
        do {
            try fm.moveItem(at: fileURL, to: backupURL)
            log("Backup criado: \(backupURL.lastPathComponent)")
        } catch {
            log("Falha ao criar backup de \(fileURL.lastPathComponent): \(error)")
        }
    }
}

// MARK: - Data helper para escrever little-endian

private extension Data {
    mutating func append<T: FixedWidthInteger>(littleEndian value: T) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { self.append(contentsOf: $0) }
    }
}
