import Foundation
import Testing
@testable import zspeak

@Suite("TranscriptionStore")
@MainActor
struct TranscriptionStoreTests {

    // MARK: - Helpers

    private func makeTmpDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    private func makeStore(in dir: URL) -> TranscriptionStore {
        TranscriptionStore(baseDirectory: dir)
    }

    private func addRecord(to store: TranscriptionStore, text: String = "texto", samples: [Float]? = nil) {
        store.addRecord(
            text: text,
            modelName: "TestModel",
            duration: 1.0,
            targetAppName: nil,
            samples: samples
        )
    }

    // MARK: - Testes

    @Test("addRecord insere no topo")
    func testAddRecordInsertsAtTop() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store = makeStore(in: tmpDir)
        addRecord(to: store, text: "primeiro")
        addRecord(to: store, text: "segundo")

        #expect(store.records.count == 2)
        #expect(store.records[0].text == "segundo")
        #expect(store.records[1].text == "primeiro")
    }

    @Test("deleteRecord remove registro")
    func testDeleteRecordRemovesEntry() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store = makeStore(in: tmpDir)
        addRecord(to: store, text: "para deletar")

        let record = try #require(store.records.first)
        store.deleteRecord(record)

        #expect(store.records.isEmpty)
    }

    @Test("deleteRecord apaga arquivo WAV")
    func testDeleteRecordRemovesWAVFile() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store = makeStore(in: tmpDir)
        let samples: [Float] = [0.1, 0.2, -0.1, 0.0]
        addRecord(to: store, samples: samples)

        let record = try #require(store.records.first)
        let wavURL = store.audioURL(for: record)
        #expect(wavURL != nil)

        store.deleteRecord(record)

        if let url = wavURL {
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test("Persistência JSON round-trip")
    func testJSONPersistenceRoundTrip() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store1 = makeStore(in: tmpDir)
        addRecord(to: store1, text: "persistência")

        let store2 = makeStore(in: tmpDir)
        #expect(store2.records.count == 1)
        #expect(store2.records[0].text == "persistência")
    }

    @Test("audioURL retorna nil quando sem áudio")
    func testAudioURLNilWhenNoSamples() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store = makeStore(in: tmpDir)
        addRecord(to: store, samples: nil)

        let record = try #require(store.records.first)
        #expect(store.audioURL(for: record) == nil)
    }

    @Test("audioURL retorna URL válida com áudio")
    func testAudioURLValidWhenHasSamples() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store = makeStore(in: tmpDir)
        let samples: [Float] = [0.1, -0.2, 0.3, 0.0]
        addRecord(to: store, samples: samples)

        let record = try #require(store.records.first)
        let url = store.audioURL(for: record)
        #expect(url != nil)
        if let url {
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test("WAV header válido: RIFF/WAVE, PCM 16-bit 16kHz")
    func testWAVHeaderValid() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store = makeStore(in: tmpDir)
        let samples: [Float] = Array(repeating: 0.5, count: 100)
        addRecord(to: store, samples: samples)

        let record = try #require(store.records.first)
        let url = try #require(store.audioURL(for: record))
        let data = try Data(contentsOf: url)

        // RIFF identifier (bytes 0-3)
        let riff = String(bytes: data[0..<4], encoding: .utf8)
        #expect(riff == "RIFF")

        // WAVE identifier (bytes 8-11)
        let wave = String(bytes: data[8..<12], encoding: .utf8)
        #expect(wave == "WAVE")

        // fmt chunk id (bytes 12-15)
        let fmt = String(bytes: data[12..<16], encoding: .utf8)
        #expect(fmt == "fmt ")

        // PCM format = 1 (bytes 20-21, little-endian)
        let audioFormat = data[20...21].withUnsafeBytes { $0.load(as: UInt16.self).littleEndian }
        #expect(audioFormat == 1)

        // Num channels = 1 (bytes 22-23)
        let numChannels = data[22...23].withUnsafeBytes { $0.load(as: UInt16.self).littleEndian }
        #expect(numChannels == 1)

        // Sample rate = 16000 (bytes 24-27)
        let sampleRate = data[24...27].withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
        #expect(sampleRate == 16000)

        // Bits per sample = 16 (bytes 34-35)
        let bitsPerSample = data[34...35].withUnsafeBytes { $0.load(as: UInt16.self).littleEndian }
        #expect(bitsPerSample == 16)
    }

    // MARK: - Retenção

    /// Defaults isolados por teste — nunca toca UserDefaults.standard.
    private func makeDefaults(limit: Int?) -> UserDefaults {
        let suite = "zspeak-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        if let limit {
            defaults.set(limit, forKey: TranscriptionStoreRetention.limitKey)
        }
        return defaults
    }

    @Test("addRecord além do limite descarta os registros mais antigos")
    func testRetentionPrunesOldestOnAdd() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store = TranscriptionStore(baseDirectory: tmpDir, userDefaults: makeDefaults(limit: 3))
        for i in 1...5 {
            addRecord(to: store, text: "registro \(i)")
        }

        #expect(store.records.count == 3)
        #expect(store.records.map(\.text) == ["registro 5", "registro 4", "registro 3"])
    }

    @Test("retenção apaga os WAVs dos registros descartados")
    func testRetentionDeletesPrunedWAVs() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store = TranscriptionStore(baseDirectory: tmpDir, userDefaults: makeDefaults(limit: 1))
        let samples: [Float] = [0.1, -0.2, 0.3, 0.0]

        addRecord(to: store, text: "antigo", samples: samples)
        let oldRecord = try #require(store.records.first)
        let oldURL = try #require(store.audioURL(for: oldRecord))

        addRecord(to: store, text: "novo", samples: samples)
        let newRecord = try #require(store.records.first)

        // audioURL drena a fila de persistência — garante que o delete rodou
        _ = store.audioURL(for: newRecord)

        #expect(store.records.count == 1)
        #expect(!FileManager.default.fileExists(atPath: oldURL.path))
    }

    @Test("limite 0 significa ilimitado")
    func testRetentionZeroMeansUnlimited() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store = TranscriptionStore(baseDirectory: tmpDir, userDefaults: makeDefaults(limit: 0))
        for i in 1...10 {
            addRecord(to: store, text: "registro \(i)")
        }

        #expect(store.records.count == 10)
    }

    @Test("init aplica retenção a histórico pré-existente maior que o limite")
    func testRetentionAppliedOnLoad() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Primeira instância sem limite acumula 6 registros
        let storeA = TranscriptionStore(baseDirectory: tmpDir, userDefaults: makeDefaults(limit: 0))
        for i in 1...6 {
            addRecord(to: storeA, text: "registro \(i)")
        }

        // Segunda instância com limite 2 poda ao carregar e persiste o corte
        let storeB = TranscriptionStore(baseDirectory: tmpDir, userDefaults: makeDefaults(limit: 2))
        #expect(storeB.records.count == 2)

        let storeC = TranscriptionStore(baseDirectory: tmpDir, userDefaults: makeDefaults(limit: 0))
        #expect(storeC.records.count == 2)
    }

    @Test("applyRetentionLimit responde a redução do limite em runtime")
    func testApplyRetentionAfterLimitChange() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let defaults = makeDefaults(limit: 10)
        let store = TranscriptionStore(baseDirectory: tmpDir, userDefaults: defaults)
        for i in 1...5 {
            addRecord(to: store, text: "registro \(i)")
        }
        #expect(store.records.count == 5)

        // Usuário reduz o limite na UI
        defaults.set(2, forKey: TranscriptionStoreRetention.limitKey)
        store.applyRetentionLimit()

        #expect(store.records.count == 2)
        #expect(store.records.map(\.text) == ["registro 5", "registro 4"])
    }

    @Test("init remove WAVs órfãos sem registro correspondente")
    func testOrphanWAVsCleanedOnInit() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let audioDir = tmpDir.appendingPathComponent("audio", isDirectory: true)
        try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        let orphanURL = audioDir.appendingPathComponent("\(UUID().uuidString).wav")
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: orphanURL)

        let store = TranscriptionStore(baseDirectory: tmpDir, userDefaults: makeDefaults(limit: nil))

        // WAV legítimo adicionado após o init deve sobreviver à varredura
        addRecord(to: store, text: "com áudio", samples: [0.1, 0.2, 0.3])
        let record = try #require(store.records.first)
        let legitURL = try #require(store.audioURL(for: record))

        #expect(!FileManager.default.fileExists(atPath: orphanURL.path))
        #expect(FileManager.default.fileExists(atPath: legitURL.path))
    }
}
