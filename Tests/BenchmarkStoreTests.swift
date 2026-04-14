import Foundation
import Testing
@testable import zspeak

@Suite("BenchmarkStore")
@MainActor
struct BenchmarkStoreTests {

    // MARK: - Helpers

    private func makeTmpDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    private func makeStore(in dir: URL) -> BenchmarkStore {
        BenchmarkStore(baseDirectory: dir)
    }

    /// Cria WAV PCM 16-bit mono 16kHz válido a partir de samples Int16
    private func createTestWAV(samples: [Int16]) -> Data {
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
        data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })   // PCM
        data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })   // mono
        data.append(contentsOf: withUnsafeBytes(of: UInt32(16000).littleEndian) { Array($0) }) // sample rate
        data.append(contentsOf: withUnsafeBytes(of: UInt32(32000).littleEndian) { Array($0) }) // byte rate
        data.append(contentsOf: withUnsafeBytes(of: UInt16(2).littleEndian) { Array($0) })   // block align
        data.append(contentsOf: withUnsafeBytes(of: UInt16(16).littleEndian) { Array($0) })  // bits per sample

        // data chunk
        data.append(contentsOf: "data".utf8)
        data.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Array($0) })
        for sample in samples {
            data.append(contentsOf: withUnsafeBytes(of: sample.littleEndian) { Array($0) })
        }

        return data
    }

    /// Escreve WAV no diretório audio/ do benchmark store e retorna o nome do arquivo
    private func placeWAV(in dir: URL, fileName: String, samples: [Int16] = [100, -200, 300]) throws {
        let audioDir = dir.appendingPathComponent("audio", isDirectory: true)
        try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        let wavData = createTestWAV(samples: samples)
        try wavData.write(to: audioDir.appendingPathComponent(fileName))
    }

    // MARK: - Testes

    @Test("addFixture adiciona e persiste")
    func testAddFixturePersists() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store = makeStore(in: tmpDir)
        store.addFixture(name: "Teste 1", expectedText: "olá mundo", audioFileName: "test.wav", duration: 2.5)

        // Verifica que foi adicionada na memória
        #expect(store.fixtures.count == 1)
        #expect(store.fixtures[0].name == "Teste 1")
        #expect(store.fixtures[0].expectedText == "olá mundo")
        #expect(store.fixtures[0].audioFileName == "test.wav")
        #expect(store.fixtures[0].duration == 2.5)
        #expect(store.fixtures[0].lastResult == nil)

        // Recarrega de outra instância para verificar persistência em disco
        let store2 = makeStore(in: tmpDir)
        #expect(store2.fixtures.count == 1)
        #expect(store2.fixtures[0].name == "Teste 1")
        #expect(store2.fixtures[0].expectedText == "olá mundo")
    }

    @Test("deleteFixture remove fixture e arquivo WAV")
    func testDeleteFixtureRemovesFixtureAndWAV() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let fileName = "delete-me.wav"
        try placeWAV(in: tmpDir, fileName: fileName)

        let store = makeStore(in: tmpDir)
        store.addFixture(name: "Para deletar", expectedText: "delete", audioFileName: fileName, duration: 1.0)

        let fixture = try #require(store.fixtures.first)

        // Verifica que WAV existe antes da exclusão
        let wavURL = store.audioURL(for: fixture)
        #expect(wavURL != nil)

        store.deleteFixture(fixture)

        // Fixture removida da lista
        #expect(store.fixtures.isEmpty)

        // Arquivo WAV removido do disco
        if let url = wavURL {
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }

        // Persistência reflete a exclusão
        let store2 = makeStore(in: tmpDir)
        #expect(store2.fixtures.isEmpty)
    }

    @Test("importWAV copia arquivo para audio/")
    func testImportWAVCopiesToAudioDir() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Cria WAV temporário fora do store
        let sourceDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: sourceDir) }
        let sourceURL = sourceDir.appendingPathComponent("source.wav")
        let wavData = createTestWAV(samples: [500, -500])
        try wavData.write(to: sourceURL)

        let store = makeStore(in: tmpDir)
        let importedFileName = try store.importWAV(from: sourceURL)

        // Verifica que o arquivo foi copiado para audio/
        let audioDir = tmpDir.appendingPathComponent("audio", isDirectory: true)
        let destURL = audioDir.appendingPathComponent(importedFileName)
        #expect(FileManager.default.fileExists(atPath: destURL.path))

        // Verifica que o conteúdo é idêntico
        let copiedData = try Data(contentsOf: destURL)
        #expect(copiedData == wavData)

        // Verifica que o nome tem formato UUID.wav
        #expect(importedFileName.hasSuffix(".wav"))
    }

    @Test("audioURL retorna URL quando WAV existe")
    func testAudioURLReturnsURLWhenFileExists() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let fileName = "exists.wav"
        try placeWAV(in: tmpDir, fileName: fileName)

        let store = makeStore(in: tmpDir)
        store.addFixture(name: "Com WAV", expectedText: "texto", audioFileName: fileName, duration: 1.0)

        let fixture = try #require(store.fixtures.first)
        let url = store.audioURL(for: fixture)
        #expect(url != nil)
        if let url {
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test("audioURL retorna nil quando WAV não existe")
    func testAudioURLReturnsNilWhenFileMissing() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store = makeStore(in: tmpDir)
        store.addFixture(name: "Sem WAV", expectedText: "texto", audioFileName: "nao-existe.wav", duration: 1.0)

        let fixture = try #require(store.fixtures.first)
        #expect(store.audioURL(for: fixture) == nil)
    }

    @Test("loadSamples lê WAV PCM válido")
    func testLoadSamplesReadsValidWAV() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let knownSamples: [Int16] = [1000, -2000, 16383]
        let fileName = "valid.wav"
        try placeWAV(in: tmpDir, fileName: fileName, samples: knownSamples)

        let store = makeStore(in: tmpDir)
        store.addFixture(name: "Válido", expectedText: "texto", audioFileName: fileName, duration: 0.5)

        let fixture = try #require(store.fixtures.first)
        let floatSamples = try store.loadSamples(for: fixture)

        // Verifica quantidade de samples
        #expect(floatSamples.count == 3)

        // Verifica normalização: Int16 / 32767.0
        let tolerance: Float = 0.0001
        #expect(abs(floatSamples[0] - Float(1000) / 32767.0) < tolerance)
        #expect(abs(floatSamples[1] - Float(-2000) / 32767.0) < tolerance)
        #expect(abs(floatSamples[2] - Float(16383) / 32767.0) < tolerance)
    }

    @Test("loadSamples lança erro com WAV inválido")
    func testLoadSamplesThrowsOnInvalidWAV() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Escreve dados menores que 44 bytes (header mínimo)
        let audioDir = tmpDir.appendingPathComponent("audio", isDirectory: true)
        try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        let invalidData = Data(repeating: 0, count: 20)
        try invalidData.write(to: audioDir.appendingPathComponent("invalid.wav"))

        let store = makeStore(in: tmpDir)
        store.addFixture(name: "Inválido", expectedText: "texto", audioFileName: "invalid.wav", duration: 0.1)

        let fixture = try #require(store.fixtures.first)

        #expect(throws: BenchmarkError.invalidWAV) {
            try store.loadSamples(for: fixture)
        }
    }

    @Test("loadSamples lança erro com WAV de exatamente 44 bytes")
    func testLoadSamplesThrowsOnExact44Bytes() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Exatamente 44 bytes = header sem dados, deve falhar (guard data.count > headerSize)
        let audioDir = tmpDir.appendingPathComponent("audio", isDirectory: true)
        try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        let headerOnly = Data(repeating: 0, count: 44)
        try headerOnly.write(to: audioDir.appendingPathComponent("header-only.wav"))

        let store = makeStore(in: tmpDir)
        store.addFixture(name: "Só header", expectedText: "texto", audioFileName: "header-only.wav", duration: 0.1)

        let fixture = try #require(store.fixtures.first)

        #expect(throws: BenchmarkError.invalidWAV) {
            try store.loadSamples(for: fixture)
        }
    }

    @Test("runBenchmark calcula latência e similaridade")
    func testRunBenchmarkCalculatesLatencyAndSimilarity() async throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let fileName = "benchmark.wav"
        try placeWAV(in: tmpDir, fileName: fileName, samples: [100, 200, 300])

        let store = makeStore(in: tmpDir)
        store.addFixture(name: "Benchmark", expectedText: "olá mundo", audioFileName: fileName, duration: 1.0)

        let fixture = try #require(store.fixtures.first)

        // Closure mock que retorna texto parcialmente igual
        try await store.runBenchmark(fixture: fixture) { _ in
            return "olá mundo"
        }

        // Verifica que resultado foi salvo na fixture
        let updated = try #require(store.fixtures.first)
        let result = try #require(updated.lastResult)

        // Latência deve ser positiva (não-zero)
        #expect(result.latency > 0)
        // Texto exato = similaridade 1.0
        #expect(result.similarity == 1.0)
        #expect(result.transcribedText == "olá mundo")
    }

    @Test("runAll executa todos os benchmarks")
    func testRunAllExecutesAllBenchmarks() async throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Cria 2 fixtures com WAVs
        try placeWAV(in: tmpDir, fileName: "first.wav", samples: [100, 200])
        try placeWAV(in: tmpDir, fileName: "second.wav", samples: [300, 400])

        let store = makeStore(in: tmpDir)
        store.addFixture(name: "Primeiro", expectedText: "primeiro", audioFileName: "first.wav", duration: 1.0)
        store.addFixture(name: "Segundo", expectedText: "segundo", audioFileName: "second.wav", duration: 1.0)

        #expect(store.fixtures.count == 2)

        await store.runAll { _ in "resultado" }

        // Ambas devem ter resultado
        for fixture in store.fixtures {
            let result = try #require(fixture.lastResult)
            #expect(result.transcribedText == "resultado")
            #expect(result.latency > 0)
        }
    }

    @Test("Persistência JSON round-trip")
    func testJSONPersistenceRoundTrip() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store1 = makeStore(in: tmpDir)
        store1.addFixture(name: "Fixture A", expectedText: "texto esperado A", audioFileName: "a.wav", duration: 2.0)
        store1.addFixture(name: "Fixture B", expectedText: "texto esperado B", audioFileName: "b.wav", duration: 3.5)

        // Recarrega de outra instância
        let store2 = makeStore(in: tmpDir)

        #expect(store2.fixtures.count == 2)

        // Verifica todos os campos de cada fixture
        #expect(store2.fixtures[0].name == "Fixture A")
        #expect(store2.fixtures[0].expectedText == "texto esperado A")
        #expect(store2.fixtures[0].audioFileName == "a.wav")
        #expect(store2.fixtures[0].duration == 2.0)

        #expect(store2.fixtures[1].name == "Fixture B")
        #expect(store2.fixtures[1].expectedText == "texto esperado B")
        #expect(store2.fixtures[1].audioFileName == "b.wav")
        #expect(store2.fixtures[1].duration == 3.5)

        // IDs devem ser preservados
        #expect(store2.fixtures[0].id == store1.fixtures[0].id)
        #expect(store2.fixtures[1].id == store1.fixtures[1].id)
    }

    @Test("Persistência JSON round-trip com resultado de benchmark")
    func testJSONPersistenceWithBenchmarkResult() async throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let fileName = "persist-result.wav"
        try placeWAV(in: tmpDir, fileName: fileName)

        let store1 = makeStore(in: tmpDir)
        store1.addFixture(name: "Com resultado", expectedText: "teste", audioFileName: fileName, duration: 1.0)

        let fixture = try #require(store1.fixtures.first)
        try await store1.runBenchmark(fixture: fixture) { _ in "teste" }

        // Recarrega e verifica que resultado persiste
        let store2 = makeStore(in: tmpDir)
        let loaded = try #require(store2.fixtures.first)
        let result = try #require(loaded.lastResult)
        #expect(result.transcribedText == "teste")
        #expect(result.similarity == 1.0)
        #expect(result.wordErrorRate == 0)
        #expect(result.characterErrorRate == 0)
        #expect(result.latency > 0)
    }

    @Test("runBenchmark: match exato gera WER/CER zero")
    func testRunBenchmarkExactMatch() async throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let fileName = "exact.wav"
        try placeWAV(in: tmpDir, fileName: fileName)

        let store = makeStore(in: tmpDir)
        store.addFixture(name: "Exato", expectedText: "olá mundo bonito", audioFileName: fileName, duration: 1.0)

        let fixture = try #require(store.fixtures.first)
        try await store.runBenchmark(fixture: fixture) { _ in "olá mundo bonito" }

        let result = try #require(store.fixtures.first?.lastResult)
        #expect(result.similarity == 1.0)
        #expect(result.wordErrorRate == 0)
        #expect(result.characterErrorRate == 0)
    }

    @Test("runBenchmark: substituição parcial gera WER previsível")
    func testRunBenchmarkPartialMatch() async throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let fileName = "partial.wav"
        try placeWAV(in: tmpDir, fileName: fileName)

        let store = makeStore(in: tmpDir)
        // Esperado: 3 palavras, transcrito tem 2 das 3
        store.addFixture(name: "Parcial", expectedText: "olá mundo bonito", audioFileName: fileName, duration: 1.0)

        let fixture = try #require(store.fixtures.first)
        try await store.runBenchmark(fixture: fixture) { _ in "olá bonito errado" }

        let result = try #require(store.fixtures.first?.lastResult)
        let tolerance = 0.01
        #expect(abs((result.wordErrorRate ?? 0) - (2.0 / 3.0)) < tolerance)
        #expect(abs(result.accuracyScore - (1.0 / 3.0)) < tolerance)
    }

    @Test("runBenchmark: nenhum match gera WER 100%")
    func testRunBenchmarkNoMatch() async throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let fileName = "nomatch.wav"
        try placeWAV(in: tmpDir, fileName: fileName)

        let store = makeStore(in: tmpDir)
        store.addFixture(name: "Zero", expectedText: "olá mundo", audioFileName: fileName, duration: 1.0)

        let fixture = try #require(store.fixtures.first)
        try await store.runBenchmark(fixture: fixture) { _ in "foo bar" }

        let result = try #require(store.fixtures.first?.lastResult)
        #expect(result.similarity == 0.0)
        #expect(result.wordErrorRate == 1.0)
    }

    @Test("runBenchmark: comparação é case insensitive")
    func testRunBenchmarkCaseInsensitive() async throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let fileName = "case.wav"
        try placeWAV(in: tmpDir, fileName: fileName)

        let store = makeStore(in: tmpDir)
        store.addFixture(name: "Case", expectedText: "Olá Mundo", audioFileName: fileName, duration: 1.0)

        let fixture = try #require(store.fixtures.first)
        try await store.runBenchmark(fixture: fixture) { _ in "olá mundo" }

        let result = try #require(store.fixtures.first?.lastResult)
        #expect(result.similarity == 1.0)
        #expect(result.wordErrorRate == 0)
    }

    @Test("runBenchmark: ambos vazios gera WER zero")
    func testRunBenchmarkBothEmpty() async throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let fileName = "empty.wav"
        try placeWAV(in: tmpDir, fileName: fileName)

        let store = makeStore(in: tmpDir)
        store.addFixture(name: "Vazio", expectedText: "", audioFileName: fileName, duration: 1.0)

        let fixture = try #require(store.fixtures.first)
        try await store.runBenchmark(fixture: fixture) { _ in "" }

        let result = try #require(store.fixtures.first?.lastResult)
        #expect(result.similarity == 1.0)
        #expect(result.wordErrorRate == 0)
        #expect(result.characterErrorRate == 0)
    }

    @Test("runBenchmark: esperado vazio e transcrito não-vazio gera erro máximo")
    func testRunBenchmarkEmptyExpectedNonEmptyActual() async throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let fileName = "empty-expected.wav"
        try placeWAV(in: tmpDir, fileName: fileName)

        let store = makeStore(in: tmpDir)
        store.addFixture(name: "Esperado vazio", expectedText: "", audioFileName: fileName, duration: 1.0)

        let fixture = try #require(store.fixtures.first)
        try await store.runBenchmark(fixture: fixture) { _ in "algo inesperado" }

        let result = try #require(store.fixtures.first?.lastResult)
        #expect(result.similarity == 0.0)
        #expect(result.wordErrorRate == 1.0)
        #expect(result.characterErrorRate == 1.0)
    }

    @Test("importFromHistory cria fixtures a partir do histórico")
    func testImportFromHistory() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Cria diretórios separados para cada store
        let historyDir = tmpDir.appendingPathComponent("history", isDirectory: true)
        try FileManager.default.createDirectory(at: historyDir, withIntermediateDirectories: true)
        let benchmarkDir = tmpDir.appendingPathComponent("benchmark", isDirectory: true)
        try FileManager.default.createDirectory(at: benchmarkDir, withIntermediateDirectories: true)

        // Cria TranscriptionStore com registros que têm WAV
        let historyStore = TranscriptionStore(baseDirectory: historyDir)
        let samples: [Float] = [0.1, -0.2, 0.3, 0.0, 0.5]
        historyStore.addRecord(
            text: "texto do histórico",
            modelName: "TestModel",
            duration: 2.5,
            targetAppName: "Terminal",
            samples: samples
        )
        historyStore.addRecord(
            text: "segunda transcrição",
            modelName: "TestModel",
            duration: 1.8,
            targetAppName: nil,
            samples: [0.4, -0.1]
        )

        // Verifica que WAVs existem no historyStore
        for record in historyStore.records {
            #expect(historyStore.audioURL(for: record) != nil)
        }

        // Importa no BenchmarkStore
        let benchmarkStore = makeStore(in: benchmarkDir)
        benchmarkStore.importFromHistory(historyStore: historyStore)

        // Deve ter criado 2 fixtures
        #expect(benchmarkStore.fixtures.count == 2)

        // Verifica que fixtures têm dados corretos do histórico
        let textos = Set(benchmarkStore.fixtures.map(\.expectedText))
        #expect(textos.contains("texto do histórico"))
        #expect(textos.contains("segunda transcrição"))

        // Verifica que os WAVs foram copiados para o diretório do benchmark
        for fixture in benchmarkStore.fixtures {
            let url = benchmarkStore.audioURL(for: fixture)
            #expect(url != nil)
        }

        // Verifica persistência
        let reloaded = makeStore(in: benchmarkDir)
        #expect(reloaded.fixtures.count == 2)
    }

    @Test("importFromHistory ignora registros sem áudio")
    func testImportFromHistorySkipsRecordsWithoutAudio() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let historyDir = tmpDir.appendingPathComponent("history", isDirectory: true)
        try FileManager.default.createDirectory(at: historyDir, withIntermediateDirectories: true)
        let benchmarkDir = tmpDir.appendingPathComponent("benchmark", isDirectory: true)
        try FileManager.default.createDirectory(at: benchmarkDir, withIntermediateDirectories: true)

        let historyStore = TranscriptionStore(baseDirectory: historyDir)
        // Registro sem samples (sem WAV)
        historyStore.addRecord(text: "sem áudio", modelName: "Test", duration: 1.0, targetAppName: nil, samples: nil)
        // Registro com samples (com WAV)
        historyStore.addRecord(text: "com áudio", modelName: "Test", duration: 1.0, targetAppName: nil, samples: [0.1, 0.2])

        let benchmarkStore = makeStore(in: benchmarkDir)
        benchmarkStore.importFromHistory(historyStore: historyStore)

        // Só o registro com WAV deve ser importado
        #expect(benchmarkStore.fixtures.count == 1)
        #expect(benchmarkStore.fixtures[0].expectedText == "com áudio")
    }

    @Test("importFromHistory não duplica WAVs já importados")
    func testImportFromHistoryNoDuplicates() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let historyDir = tmpDir.appendingPathComponent("history", isDirectory: true)
        try FileManager.default.createDirectory(at: historyDir, withIntermediateDirectories: true)
        let benchmarkDir = tmpDir.appendingPathComponent("benchmark", isDirectory: true)
        try FileManager.default.createDirectory(at: benchmarkDir, withIntermediateDirectories: true)

        let historyStore = TranscriptionStore(baseDirectory: historyDir)
        historyStore.addRecord(text: "texto", modelName: "Test", duration: 1.0, targetAppName: nil, samples: [0.1, 0.2])

        let benchmarkStore = makeStore(in: benchmarkDir)

        // Importa duas vezes
        benchmarkStore.importFromHistory(historyStore: historyStore)
        benchmarkStore.importFromHistory(historyStore: historyStore)

        // Segundo import não deve duplicar (mesmo audioFileName já existe no audio/)
        #expect(benchmarkStore.fixtures.count == 1)
    }
}
