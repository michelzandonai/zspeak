import Foundation

/// Camada de persistência e execução de benchmarks de transcrição
@Observable
@MainActor
final class BenchmarkStore {
    var fixtures: [BenchmarkFixture] = []

    private let baseDir: URL
    private let audioDir: URL
    private let fixturesFile: URL

    /// Init padrão do app — NÃO faz I/O síncrono. A view deve chamar `loadFixturesAsync()`.
    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let defaultBase = base.appendingPathComponent("zspeak", isDirectory: true)
            .appendingPathComponent("benchmarks", isDirectory: true)
        baseDir = defaultBase
        audioDir = defaultBase.appendingPathComponent("audio", isDirectory: true)
        fixturesFile = defaultBase.appendingPathComponent("fixtures.json")
        try? FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        // Não carrega fixtures no init — evita bloquear startup/abertura da aba.
    }

    /// Init usado em testes: carrega síncrono para preservar semântica determinística.
    init(baseDirectory: URL) {
        baseDir = baseDirectory
        audioDir = baseDirectory.appendingPathComponent("audio", isDirectory: true)
        fixturesFile = baseDirectory.appendingPathComponent("fixtures.json")
        try? FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        fixtures = loadFixtures()
    }

    /// Carrega fixtures do disco fora da main actor; publica no main.
    func loadFixturesAsync() async {
        let file = fixturesFile
        let loaded = await Task.detached(priority: .utility) { () -> [BenchmarkFixture] in
            guard FileManager.default.fileExists(atPath: file.path),
                  let data = try? Data(contentsOf: file) else {
                return []
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return (try? decoder.decode([BenchmarkFixture].self, from: data)) ?? []
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

    /// Remove fixture e seu arquivo WAV do disco
    func deleteFixture(_ fixture: BenchmarkFixture) {
        fixtures.removeAll { $0.id == fixture.id }
        let fileURL = audioDir.appendingPathComponent(fixture.audioFileName)
        try? FileManager.default.removeItem(at: fileURL)
        saveJSON()
    }

    /// Copia WAV para benchmarks/audio/, retorna fileName (UUID.wav)
    func importWAV(from sourceURL: URL) throws -> String {
        let fileName = "\(UUID().uuidString).wav"
        let destURL = audioDir.appendingPathComponent(fileName)
        try FileManager.default.copyItem(at: sourceURL, to: destURL)
        return fileName
    }

    /// Retorna URL do arquivo WAV se existir
    func audioURL(for fixture: BenchmarkFixture) -> URL? {
        let url = audioDir.appendingPathComponent(fixture.audioFileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Lê WAV PCM 16-bit LE mono 16kHz, retorna samples Float normalizados
    func loadSamples(for fixture: BenchmarkFixture) throws -> [Float] {
        let url = audioDir.appendingPathComponent(fixture.audioFileName)
        let data = try Data(contentsOf: url)

        // Pular 44 bytes do header RIFF/WAV
        let headerSize = 44
        guard data.count > headerSize else {
            throw BenchmarkError.invalidWAV
        }

        let pcmData = data.dropFirst(headerSize)
        let sampleCount = pcmData.count / 2 // Int16 = 2 bytes

        var samples = [Float](repeating: 0, count: sampleCount)
        pcmData.withUnsafeBytes { rawBuffer in
            let int16Buffer = rawBuffer.bindMemory(to: Int16.self)
            for i in 0..<sampleCount {
                // Int16 little-endian → Float normalizado [-1.0, 1.0]
                samples[i] = Float(Int16(littleEndian: int16Buffer[i])) / 32767.0
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

    /// Executa todos os benchmarks sequencialmente
    func runAll(transcribe: ([Float]) async throws -> String) async {
        for fixture in fixtures {
            try? await runBenchmark(fixture: fixture, transcribe: transcribe)
        }
    }

    /// Importa transcrições do histórico como fixtures de benchmark
    func importFromHistory(historyStore: TranscriptionStore) {
        let fm = FileManager.default

        for record in historyStore.records {
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
        }

        saveJSON()
    }

    // MARK: - Persistência JSON

    private func saveJSON() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted

        guard let data = try? encoder.encode(fixtures) else { return }
        try? data.write(to: fixturesFile, options: .atomic)
    }

    private func loadFixtures() -> [BenchmarkFixture] {
        guard FileManager.default.fileExists(atPath: fixturesFile.path),
              let data = try? Data(contentsOf: fixturesFile) else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return (try? decoder.decode([BenchmarkFixture].self, from: data)) ?? []
    }
}

// MARK: - Erros

enum BenchmarkError: Error, LocalizedError {
    case invalidWAV

    var errorDescription: String? {
        switch self {
        case .invalidWAV:
            return "Arquivo WAV inválido ou muito pequeno"
        }
    }
}
