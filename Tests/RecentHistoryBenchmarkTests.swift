import Foundation
import Testing
@testable import zspeak

@Suite("Benchmark - historico recente local")
@MainActor
struct RecentHistoryBenchmarkTests {

    @Test("Mede as ultimas 20 transcricoes locais com audio")
    func benchmarkRecentLocalHistory() async throws {
        let runFlag = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("build", isDirectory: true)
            .appendingPathComponent("run-recent-history-benchmark.flag")
        guard ProcessInfo.processInfo.environment["ZSPEAK_RUN_RECENT_HISTORY_BENCHMARK"] == "1"
            || FileManager.default.fileExists(atPath: runFlag.path)
        else {
            print("SKIP: defina ZSPEAK_RUN_RECENT_HISTORY_BENCHMARK=1 para medir as ultimas 20 transcricoes locais")
            return
        }

        let historyStore = TranscriptionStore()
        let recentRecords = historyStore.records
            .filter { record in
                record.sourceRecordID == nil
                    && !record.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && historyStore.audioURL(for: record) != nil
            }
            .sorted { $0.timestamp > $1.timestamp }

        let records = Array(recentRecords.prefix(20))
        guard !records.isEmpty else {
            print("SKIP: nao ha transcricoes locais recentes com audio salvo")
            return
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zspeak-recent-history-benchmark-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let benchmarkStore = BenchmarkStore(baseDirectory: tempDir)
        let audioDir = tempDir.appendingPathComponent("audio", isDirectory: true)
        try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)

        var recordByAudioFileName: [String: TranscriptionRecord] = [:]
        for record in records {
            guard let sourceURL = historyStore.audioURL(for: record) else { continue }
            let fileName = sourceURL.lastPathComponent
            let destinationURL = audioDir.appendingPathComponent(fileName)
            if !FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            }
            recordByAudioFileName[fileName] = record
            benchmarkStore.addFixture(
                name: record.timestamp.formatted(date: .abbreviated, time: .standard),
                expectedText: record.text,
                audioFileName: fileName,
                duration: record.duration
            )
        }

        let transcriber = Transcriber()
        try await transcriber.initialize()

        for fixture in benchmarkStore.fixtures {
            try await benchmarkStore.runBenchmark(fixture: fixture) { samples in
                try await transcriber.transcribe(samples)
            }
        }

        let rows = benchmarkStore.fixtures.compactMap { fixture -> RecentHistoryBenchmarkRow? in
            guard let result = fixture.lastResult else { return nil }
            let record = recordByAudioFileName[fixture.audioFileName]
            return RecentHistoryBenchmarkRow(
                timestamp: record?.timestamp ?? Date.distantPast,
                audioFileName: fixture.audioFileName,
                duration: fixture.duration,
                latency: result.latency,
                realtimeFactor: fixture.duration > 0 ? result.latency / fixture.duration : nil,
                accuracy: result.accuracyScore,
                wordErrorRate: result.wordErrorRate,
                characterErrorRate: result.characterErrorRate,
                expectedText: fixture.expectedText,
                transcribedText: result.transcribedText
            )
        }

        #expect(!rows.isEmpty)

        let run = RecentHistoryBenchmarkRun(createdAt: Date(), rows: rows)
        let outputDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("build", isDirectory: true)
            .appendingPathComponent("recent-history-benchmark", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let jsonData = try encoder.encode(run)
        try jsonData.write(to: outputDir.appendingPathComponent("latest.json"), options: .atomic)

        let markdown = renderRecentHistoryMarkdown(run)
        try markdown.data(using: .utf8)?.write(
            to: outputDir.appendingPathComponent("latest.md"),
            options: .atomic
        )

        print(markdown)
    }
}

private struct RecentHistoryBenchmarkRun: Codable {
    let createdAt: Date
    let rows: [RecentHistoryBenchmarkRow]

    var summary: RecentHistoryBenchmarkSummary {
        RecentHistoryBenchmarkSummary(rows: rows)
    }
}

private struct RecentHistoryBenchmarkRow: Codable {
    let timestamp: Date
    let audioFileName: String
    let duration: TimeInterval
    let latency: TimeInterval
    let realtimeFactor: Double?
    let accuracy: Double
    let wordErrorRate: Double?
    let characterErrorRate: Double?
    let expectedText: String
    let transcribedText: String
}

private struct RecentHistoryBenchmarkSummary: Codable {
    let count: Int
    let averageLatency: TimeInterval
    let p95Latency: TimeInterval
    let maxLatency: TimeInterval
    let averageRealtimeFactor: Double?
    let averageAccuracy: Double
    let averageWordErrorRate: Double?
    let averageCharacterErrorRate: Double?
    let slowCount: Int

    init(rows: [RecentHistoryBenchmarkRow]) {
        count = rows.count
        let latencies = rows.map(\.latency).sorted()
        averageLatency = Self.average(rows.map(\.latency))
        p95Latency = Self.percentile(latencies, percentile: 0.95)
        maxLatency = latencies.last ?? 0
        let rtfs = rows.compactMap(\.realtimeFactor)
        averageRealtimeFactor = rtfs.isEmpty ? nil : Self.average(rtfs)
        averageAccuracy = Self.average(rows.map(\.accuracy))
        let wers = rows.compactMap(\.wordErrorRate)
        averageWordErrorRate = wers.isEmpty ? nil : Self.average(wers)
        let cers = rows.compactMap(\.characterErrorRate)
        averageCharacterErrorRate = cers.isEmpty ? nil : Self.average(cers)
        slowCount = rows.filter { row in
            row.latency > 2.5 || (row.realtimeFactor ?? 0) > 0.8
        }.count
    }

    private static func average(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func percentile(_ sortedValues: [Double], percentile: Double) -> Double {
        guard !sortedValues.isEmpty else { return 0 }
        let clamped = min(1, max(0, percentile))
        let index = Int((Double(sortedValues.count - 1) * clamped).rounded(.up))
        return sortedValues[min(index, sortedValues.count - 1)]
    }
}

private func renderRecentHistoryMarkdown(_ run: RecentHistoryBenchmarkRun) -> String {
    let summary = run.summary
    var lines: [String] = []
    lines.append("# Benchmark das ultimas 20 transcricoes locais")
    lines.append("")
    lines.append("Gerado em: \(run.createdAt.formatted(date: .abbreviated, time: .standard))")
    lines.append("")
    lines.append("## Resumo")
    lines.append("- Casos: \(summary.count)")
    lines.append("- Latencia media: \(formatSeconds(summary.averageLatency))")
    lines.append("- P95 latencia: \(formatSeconds(summary.p95Latency))")
    lines.append("- Pior caso: \(formatSeconds(summary.maxLatency))")
    if let rtf = summary.averageRealtimeFactor {
        lines.append("- RTF medio: \(format(rtf))x")
    }
    lines.append("- Acuracia media local: \(formatPercent(summary.averageAccuracy))")
    if let wer = summary.averageWordErrorRate {
        lines.append("- WER medio local: \(formatPercent(wer))")
    }
    if let cer = summary.averageCharacterErrorRate {
        lines.append("- CER medio local: \(formatPercent(cer))")
    }
    lines.append("- Casos lentos: \(summary.slowCount)")
    lines.append("")
    lines.append("> Nota: o texto salvo no historico e usado como referencia local. Isso mede regressao/estabilidade, nao ground truth humano.")
    lines.append("")

    lines.append("## Mais lentos")
    lines.append("| Quando | Duracao | Latencia | RTF | Acc local | WER local | Esperado | Transcrito |")
    lines.append("|---|---:|---:|---:|---:|---:|---|---|")
    for row in run.rows.sorted(by: { $0.latency > $1.latency }).prefix(10) {
        lines.append(rowMarkdown(row))
    }

    lines.append("")
    lines.append("## Maior erro")
    lines.append("| Quando | Duracao | Latencia | RTF | Acc local | WER local | Esperado | Transcrito |")
    lines.append("|---|---:|---:|---:|---:|---:|---|---|")
    for row in run.rows.sorted(by: { ($0.wordErrorRate ?? 0) > ($1.wordErrorRate ?? 0) }).prefix(10) {
        lines.append(rowMarkdown(row))
    }

    return lines.joined(separator: "\n")
}

private func rowMarkdown(_ row: RecentHistoryBenchmarkRow) -> String {
    "| \(row.timestamp.formatted(date: .abbreviated, time: .shortened)) | \(formatSeconds(row.duration)) | \(formatSeconds(row.latency)) | \(row.realtimeFactor.map { "\(format($0))x" } ?? "-") | \(formatPercent(row.accuracy)) | \(row.wordErrorRate.map { formatPercent($0) } ?? "-") | \(escapeMarkdown(row.expectedText)) | \(escapeMarkdown(row.transcribedText)) |"
}

private func formatSeconds(_ value: Double) -> String {
    if value < 1 {
        return String(format: "%.0fms", value * 1000)
    }
    return String(format: "%.2fs", value)
}

private func format(_ value: Double) -> String {
    String(format: "%.2f", value)
}

private func formatPercent(_ value: Double) -> String {
    String(format: "%.1f%%", value * 100)
}

private func escapeMarkdown(_ text: String) -> String {
    text
        .replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: "|", with: "\\|")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}
