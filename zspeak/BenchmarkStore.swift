import Foundation

/// Camada de persistência e execução de benchmarks de transcrição
@Observable
@MainActor
final class BenchmarkStore {
    var fixtures: [BenchmarkFixture] = []

    private let baseDir: URL
    private let audioDir: URL
    private let fixturesFile: URL

    /// Fila serial dedicada a encode + I/O do JSON de fixtures. Fora da main thread.
    @ObservationIgnored
    private let persistQueue: DispatchQueue

    /// Init padrão do app — NÃO faz I/O síncrono. A view deve chamar `loadFixturesAsync()`.
    init() {
        let base = SafePath.firstURL(for: .applicationSupportDirectory)
        let defaultBase = base.appendingPathComponent("zspeak", isDirectory: true)
            .appendingPathComponent("benchmarks", isDirectory: true)
        baseDir = defaultBase
        audioDir = defaultBase.appendingPathComponent("audio", isDirectory: true)
        fixturesFile = defaultBase.appendingPathComponent("fixtures.json")
        persistQueue = StorePersistQueue.shared(forFileAt: fixturesFile)
        try? FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        // Não carrega fixtures no init — evita bloquear startup/abertura da aba.
    }

    /// Init usado em testes: carrega síncrono para preservar semântica determinística.
    init(baseDirectory: URL) {
        baseDir = baseDirectory
        audioDir = baseDirectory.appendingPathComponent("audio", isDirectory: true)
        fixturesFile = baseDirectory.appendingPathComponent("fixtures.json")
        persistQueue = StorePersistQueue.shared(forFileAt: fixturesFile)
        try? FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        fixtures = loadFixtures()
    }

    /// Carrega fixtures do disco fora da main actor; publica no main.
    func loadFixturesAsync() async {
        let file = fixturesFile
        let loaded = await Task.detached(priority: .utility) { () -> [BenchmarkFixture] in
            return decodeFixturesFile(at: file)
        }.value
        // Só sobrescreve se ainda estiver vazio — evita sobrescrever edições feitas enquanto carregava.
        if fixtures.isEmpty {
            fixtures = loaded
        }
    }

    /// Retorna conjunto com nomes de arquivo de áudio existentes em disco (uma varredura só).
    func availableAudioFileNames() -> Set<String> {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: audioDir.path) else { return [] }
        return Set(items)
    }

    // MARK: - API pública

    /// Adiciona uma fixture e salva no JSON
    func addFixture(name: String, expectedText: String, audioFileName: String, duration: TimeInterval) {
        let fixture = BenchmarkFixture(
            id: UUID(),
            name: name,
            expectedText: expectedText,
            audioFileName: audioFileName,
            duration: duration,
            lastResult: nil
        )
        fixtures.append(fixture)
        saveJSON()
    }

    /// Remove fixture e seu arquivo WAV do disco.
    /// O `removeItem` é rápido e fica síncrono para que callers que checam
    /// `fileExists` imediatamente após a remoção vejam o arquivo removido.
    func deleteFixture(_ fixture: BenchmarkFixture) {
        fixtures.removeAll { $0.id == fixture.id }
        let fileURL = audioDir.appendingPathComponent(fixture.audioFileName)
        try? FileManager.default.removeItem(at: fileURL)
        saveJSON()
    }

    /// Copia WAV para benchmarks/audio/, retorna fileName (UUID.wav).
    /// Síncrono pois callers (view de import) esperam o fileName retornado logo em seguida.
    func importWAV(from sourceURL: URL) throws -> String {
        let fileName = "\(UUID().uuidString).wav"
        let destURL = audioDir.appendingPathComponent(fileName)
        try FileManager.default.copyItem(at: sourceURL, to: destURL)
        return fileName
    }

    /// Retorna URL do arquivo WAV se existir.
    /// Drena writes pendentes antes de consultar.
    func audioURL(for fixture: BenchmarkFixture) -> URL? {
        persistQueue.sync { }
        let url = audioDir.appendingPathComponent(fixture.audioFileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Lê WAV PCM 16-bit LE 16 kHz, retorna samples Float normalizados (mono;
    /// múltiplos canais são mixados por média).
    ///
    /// Parseia os chunks RIFF de verdade em vez de pular 44 bytes fixos: WAVs
    /// do CoreAudio (`say`, `afconvert`, `AVAudioFile`) frequentemente inserem
    /// chunk `FLLR` de padding antes do `data` — o skip fixo interpretava
    /// header+padding como PCM e alimentava lixo silencioso ao ASR (WER ~100%
    /// sem nenhum erro reportado). Também valida o `fmt `: WAV importado com
    /// 44,1 kHz/float32/estéreo agora falha com mensagem clara em vez de
    /// corromper o benchmark.
    func loadSamples(for fixture: BenchmarkFixture) throws -> [Float] {
        let url = audioDir.appendingPathComponent(fixture.audioFileName)
        let data = try Data(contentsOf: url)
        return try Self.decodeWAV(data)
    }

    // Função pura — nonisolated para poder decodificar fora da main thread.
    nonisolated static func decodeWAV(_ data: Data) throws -> [Float] {
        guard data.count >= 44,
              data[0..<4].elementsEqual("RIFF".utf8),
              data[8..<12].elementsEqual("WAVE".utf8) else {
            throw BenchmarkError.invalidWAV
        }

        func readUInt32(_ offset: Int) -> UInt32 {
            UInt32(data[offset]) | UInt32(data[offset + 1]) << 8
                | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
        }
        func readUInt16(_ offset: Int) -> UInt16 {
            UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
        }

        var audioFormat: UInt16 = 0
        var channels: Int = 0
        var sampleRate: Int = 0
        var bitsPerSample: Int = 0
        var pcmRange: Range<Int>?

        // Varre os chunks: "fmt " descreve o formato; "data" contém o PCM.
        var offset = 12
        while offset + 8 <= data.count {
            let chunkID = data[offset..<(offset + 4)]
            let chunkSize = Int(readUInt32(offset + 4))
            let body = offset + 8
            guard chunkSize >= 0, body <= data.count else { break }
            let bodyEnd = min(body + chunkSize, data.count)

            // `bodyEnd - body >= 16` (e não só chunkSize): um arquivo truncado
            // no meio do fmt declararia 16 bytes sem contê-los — crash no read.
            if chunkID.elementsEqual("fmt ".utf8), bodyEnd - body >= 16 {
                audioFormat = readUInt16(body)
                channels = Int(readUInt16(body + 2))
                sampleRate = Int(readUInt32(body + 4))
                bitsPerSample = Int(readUInt16(body + 14))
            } else if chunkID.elementsEqual("data".utf8) {
                pcmRange = body..<bodyEnd
            }

            // Chunks RIFF são alinhados em 2 bytes.
            offset = body + chunkSize + (chunkSize % 2)
        }

        guard let pcmRange, channels > 0 else {
            throw BenchmarkError.invalidWAV
        }
        // 1 = PCM linear; 0xFFFE = WAVE_FORMAT_EXTENSIBLE (aceito se 16-bit).
        guard audioFormat == 1 || audioFormat == 0xFFFE, bitsPerSample == 16 else {
            throw BenchmarkError.unsupportedFormat(
                detail: "formato \(audioFormat), \(bitsPerSample)-bit — o benchmark aceita PCM 16-bit"
            )
        }
        guard sampleRate == 16_000 else {
            throw BenchmarkError.unsupportedFormat(
                detail: "\(sampleRate) Hz — converta para 16 kHz (ex.: afconvert -d LEI16@16000 -c 1)"
            )
        }

        let pcmData = data[pcmRange]
        let frameCount = pcmData.count / (2 * channels)
        var samples = [Float](repeating: 0, count: frameCount)
        // Leitura byte a byte: WAV malformado pode deixar o PCM em offset
        // ímpar, e `bindMemory(to: Int16.self)` desalinhado é UB.
        pcmData.withUnsafeBytes { rawBuffer in
            let scale = Float(1.0 / 32767.0)
            for frame in 0..<frameCount {
                var sum: Float = 0
                for channel in 0..<channels {
                    let byteIndex = (frame * channels + channel) * 2
                    let raw = UInt16(rawBuffer[byteIndex]) | (UInt16(rawBuffer[byteIndex + 1]) << 8)
                    sum += Float(Int16(bitPattern: raw))
                }
                samples[frame] = (sum / Float(channels)) * scale
            }
        }

        return samples
    }

    /// Executa benchmark para uma fixture usando closure de transcrição.
    /// Usa WER/CER, que são mais confiáveis para regressão de ASR do que word overlap.
    func runBenchmark(
        fixture: BenchmarkFixture,
        transcribe: ([Float]) async throws -> String
    ) async throws {
        let samples = try loadSamples(for: fixture)

        let clock = ContinuousClock()
        let start = clock.now
        let transcribedText = try await transcribe(samples)
        let elapsed = clock.now - start
        let latency = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18

        let wordErrorRate = BenchmarkMetrics.wordErrorRate(
            expected: fixture.expectedText,
            actual: transcribedText
        )
        let characterErrorRate = BenchmarkMetrics.characterErrorRate(
            expected: fixture.expectedText,
            actual: transcribedText
        )
        let similarity = BenchmarkMetrics.accuracyScore(
            expected: fixture.expectedText,
            actual: transcribedText
        )

        let result = BenchmarkResult(
            transcribedText: transcribedText,
            latency: latency,
            timestamp: Date(),
            similarity: similarity,
            wordErrorRate: wordErrorRate,
            characterErrorRate: characterErrorRate
        )

        // Atualizar fixture com resultado
        if let index = fixtures.firstIndex(where: { $0.id == fixture.id }) {
            fixtures[index].lastResult = result
            saveJSON()
        }
    }

    /// Executa todos os benchmarks sequencialmente.
    /// A primeira inferência após o load do modelo CoreML inclui a
    /// especialização do grafo para o ANE — sem warm-up, esse custo contamina
    /// a latência da primeira fixture (e o max/p95 do agregado).
    func runAll(transcribe: ([Float]) async throws -> String) async {
        await warmUpTranscriber(transcribe)
        for fixture in fixtures {
            try? await runBenchmark(fixture: fixture, transcribe: transcribe)
        }
    }

    /// Inferência descartada de 1 s de silêncio para aquecer o grafo CoreML.
    private func warmUpTranscriber(_ transcribe: ([Float]) async throws -> String) async {
        _ = try? await transcribe([Float](repeating: 0, count: 16_000))
    }

    /// Avalia um perfil sem sobrescrever `lastResult` das fixtures.
    ///
    /// Use para comparar tuning de ASR/LLM antes de adotar o candidato como
    /// padrão. Retorna médias de WER/CER/latência sobre as fixtures que rodaram
    /// com sucesso e conta falhas separadamente.
    func evaluateProfile(
        name: String,
        transcribe: ([Float]) async throws -> String
    ) async -> BenchmarkProfileSummary {
        // Warm-up também aqui: em `compareProfiles`, o baseline rodava frio e
        // o candidato herdava caches quentes — viés sistemático de ordem.
        await warmUpTranscriber(transcribe)

        var wordErrorRates: [Double] = []
        var characterErrorRates: [Double] = []
        var latencies: [TimeInterval] = []
        var failedCount = 0

        for fixture in fixtures {
            do {
                let result = try await evaluateFixture(fixture, transcribe: transcribe)
                wordErrorRates.append(result.wordErrorRate)
                characterErrorRates.append(result.characterErrorRate)
                latencies.append(result.latency)
            } catch {
                failedCount += 1
            }
        }

        return BenchmarkProfileSummary(
            profileName: name,
            fixtureCount: fixtures.count,
            successfulCount: wordErrorRates.count,
            failedCount: failedCount,
            averageWordErrorRate: Self.average(wordErrorRates),
            averageCharacterErrorRate: Self.average(characterErrorRates),
            averageLatency: Self.average(latencies)
        )
    }

    /// Compara dois perfis sobre o mesmo conjunto de fixtures.
    func compareProfiles(
        baselineName: String,
        baseline: ([Float]) async throws -> String,
        candidateName: String,
        candidate: ([Float]) async throws -> String
    ) async -> BenchmarkProfileComparison {
        let baselineSummary = await evaluateProfile(name: baselineName, transcribe: baseline)
        let candidateSummary = await evaluateProfile(name: candidateName, transcribe: candidate)
        return BenchmarkProfileComparison(
            baseline: baselineSummary,
            candidate: candidateSummary
        )
    }

    /// Importa transcrições do histórico como fixtures de benchmark.
    ///
    /// Quando `limit` é informado, pega apenas as transcrições mais recentes.
    /// Registros gerados por correção LLM são ignorados porque normalmente não
    /// representam áudio original.
    @discardableResult
    func importFromHistory(historyStore: TranscriptionStore, limit: Int? = nil) -> Int {
        let fm = FileManager.default
        let sortedRecords = historyStore.records
            .filter { $0.sourceRecordID == nil }
            .sorted { $0.timestamp > $1.timestamp }
        let recordsToImport: [TranscriptionRecord]
        if let limit {
            recordsToImport = Array(sortedRecords.prefix(limit))
        } else {
            recordsToImport = sortedRecords
        }

        var importedCount = 0
        for record in recordsToImport {
            guard let sourceURL = historyStore.audioURL(for: record) else { continue }

            let destURL = audioDir.appendingPathComponent(sourceURL.lastPathComponent)

            // Só importa se o WAV ainda não existe no benchmarks/audio/
            guard !fm.fileExists(atPath: destURL.path) else { continue }

            do {
                try fm.copyItem(at: sourceURL, to: destURL)
            } catch {
                continue
            }

            let fixture = BenchmarkFixture(
                id: UUID(),
                name: record.text.prefix(60).description,
                expectedText: record.text,
                audioFileName: sourceURL.lastPathComponent,
                duration: record.duration,
                lastResult: nil
            )
            fixtures.append(fixture)
            importedCount += 1
        }

        saveJSON()
        return importedCount
    }

    // MARK: - Persistência JSON

    private struct BenchmarkFixtureEvaluation {
        let wordErrorRate: Double
        let characterErrorRate: Double
        let latency: TimeInterval
    }

    private func evaluateFixture(
        _ fixture: BenchmarkFixture,
        transcribe: ([Float]) async throws -> String
    ) async throws -> BenchmarkFixtureEvaluation {
        let samples = try loadSamples(for: fixture)

        let clock = ContinuousClock()
        let start = clock.now
        let transcribedText = try await transcribe(samples)
        let elapsed = clock.now - start
        let latency = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18

        return BenchmarkFixtureEvaluation(
            wordErrorRate: BenchmarkMetrics.wordErrorRate(
                expected: fixture.expectedText,
                actual: transcribedText
            ),
            characterErrorRate: BenchmarkMetrics.characterErrorRate(
                expected: fixture.expectedText,
                actual: transcribedText
            ),
            latency: latency
        )
    }

    private static func average(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    /// Envelope versionado: `{ schemaVersion: 1, fixtures: [...] }`.
    fileprivate struct Envelope: Codable {
        let schemaVersion: Int
        let fixtures: [BenchmarkFixture]
    }

    /// Captura snapshot no main e enfileira encode+write no background.
    private func saveJSON() {
        let snapshot = fixtures
        let file = fixturesFile
        persistQueue.async {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

            let envelope = Envelope(
                schemaVersion: BenchmarkStoreSchema.currentVersion,
                fixtures: snapshot
            )

            guard let data = try? encoder.encode(envelope) else { return }
            try? data.write(to: file, options: .atomic)
        }
    }

    /// Load síncrono do disco — drena pendentes antes de ler.
    /// Só chamado pelo init de testes; o app usa `loadFixturesAsync()`.
    private func loadFixtures() -> [BenchmarkFixture] {
        persistQueue.sync { }
        return decodeFixturesFile(at: fixturesFile)
    }
}

// MARK: - Constants / schema

/// Versão corrente do schema persistido de `BenchmarkStore`.
enum BenchmarkStoreSchema {
    static let currentVersion = 1
}

/// Decodifica o arquivo de fixtures com fallback de versão / legado.
/// Pure (sem estado) — safe para `Task.detached`.
fileprivate func decodeFixturesFile(at file: URL) -> [BenchmarkFixture] {
    guard FileManager.default.fileExists(atPath: file.path) else {
        return []
    }

    let data: Data
    do {
        data = try Data(contentsOf: file)
    } catch {
        StoreLog.shared.log("BenchmarkStore: falha ao ler \(file.lastPathComponent): \(error)")
        return []
    }

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    if let envelope = try? decoder.decode(BenchmarkStore.Envelope.self, from: data) {
        if envelope.schemaVersion == BenchmarkStoreSchema.currentVersion {
            return envelope.fixtures
        }
        StoreLog.shared.log("BenchmarkStore: schemaVersion desconhecida \(envelope.schemaVersion); fazendo backup e começando vazio")
        StoreLog.shared.backup(fileURL: file)
        return []
    }

    if let legacy = try? decoder.decode([BenchmarkFixture].self, from: data) {
        return legacy
    }

    StoreLog.shared.log("BenchmarkStore: JSON malformado em \(file.lastPathComponent); fazendo backup")
    StoreLog.shared.backup(fileURL: file)
    return []
}

// MARK: - Erros

enum BenchmarkError: Error, LocalizedError, Equatable {
    case invalidWAV
    case unsupportedFormat(detail: String)

    var errorDescription: String? {
        switch self {
        case .invalidWAV:
            return "Arquivo WAV inválido ou muito pequeno"
        case .unsupportedFormat(let detail):
            return "Formato de WAV não suportado: \(detail)"
        }
    }
}
