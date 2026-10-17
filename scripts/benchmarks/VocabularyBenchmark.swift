import Darwin
import Foundation

@main
struct VocabularyBenchmark {
    struct Scenario {
        let name: String
        let entries: [VocabularyEntry]
        let text: String
        let iterations: Int
    }

    static func main() throws {
        let entries = vocabulary(count: 128)
        let technical = "Abra cloud code e rode git pool, x code build, type script e post gree. "
        let accentedEntries = (0..<128).map {
            VocabularyEntry(term: "Tecnologia\($0)", aliases: ["técnico alias \($0)"])
        }
        let accentedText = "Revisar técnico alias 0, técnico alias 31, técnico alias 64, técnico alias 95 e técnico alias 127. "
        let scenarios = [
            Scenario(name: "short-no-match", entries: entries, text: "Pode revisar o arquivo e confirmar o resultado?", iterations: 100),
            Scenario(name: "short-technical", entries: entries, text: technical, iterations: 100),
            Scenario(name: "long-technical", entries: entries, text: String(repeating: technical, count: 100), iterations: 10),
            Scenario(name: "large-vocabulary", entries: vocabulary(count: 1024), text: technical, iterations: 25),
            Scenario(name: "accented-vocabulary", entries: accentedEntries, text: accentedText, iterations: 50),
            Scenario(name: "accented-long-text", entries: accentedEntries, text: String(repeating: accentedText, count: 20), iterations: 10)
        ]
        var measurements: [[String: Any]] = []
        for scenario in scenarios {
            let reference = VocabularyReplacementReference(entries: scenario.entries)
            let current = VocabularyReplacements(entries: scenario.entries)
            let expected = reference.apply(to: scenario.text)
            precondition(current.apply(to: scenario.text) == expected, "Mudança inesperada fora do corpus: \(scenario.name)")
            for mode in ["cold", "warm"] {
                let iterations = mode == "cold" ? 1 : scenario.iterations
                var baselineTimes: [Double] = []
                var candidateTimes: [Double] = []
                for trial in 0..<9 {
                    for baseline in trial.isMultiple(of: 2) ? [true, false] : [false, true] {
                        var outputs: [String] = []
                        outputs.reserveCapacity(iterations)
                        let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                        for _ in 0..<iterations {
                            if baseline {
                                let plan = mode == "cold" ? VocabularyReplacementReference(entries: scenario.entries) : reference
                                outputs.append(plan.apply(to: scenario.text))
                            } else {
                                let plan = mode == "cold" ? VocabularyReplacements(entries: scenario.entries) : current
                                outputs.append(plan.apply(to: scenario.text))
                            }
                        }
                        let ms = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / 1e6 / Double(iterations)
                        precondition(outputs.allSatisfy { $0.utf8.elementsEqual(expected.utf8) }, "Texto diferente em \(scenario.name)")
                        if baseline { baselineTimes.append(ms) } else { candidateTimes.append(ms) }
                    }
                }
                let baselineMedian = baselineTimes.sorted()[4]
                let candidateMedian = candidateTimes.sorted()[4]
                measurements.append([
                    "name": scenario.name, "cache": mode, "aliases": scenario.entries.count,
                    "non_ascii_aliases": scenario.entries.flatMap(\.aliases).filter { !$0.utf8.allSatisfy { $0 < 128 } }.count,
                    "input_utf8_bytes": scenario.text.utf8.count, "iterations_per_trial": iterations,
                    "baseline_ms": baselineTimes, "candidate_ms": candidateTimes,
                    "baseline_median_ms": baselineMedian, "candidate_median_ms": candidateMedian,
                    "speedup": baselineMedian / candidateMedian, "identical_utf8": true
                ])
            }
        }

        var regressions: [[String: Any]] = []
        for row in TextPostProcessingRegressionCorpus.vocabulary {
            let before = VocabularyReplacementReference(entries: row.entries).apply(to: row.input)
            let after = VocabularyReplacements(entries: row.entries).apply(to: row.input)
            precondition(before != row.expected && after == row.expected, "Regressão não comprovada: \(row.name)")
            regressions.append(["name": row.name, "stage": "vocabulary", "input": row.input, "before": before, "after": after, "expected": row.expected])
        }
        for row in TextPostProcessingRegressionCorpus.numbers {
            let before = PTBRTextNormalizerReference.normalize(row.input)
            let after = PTBRTextNormalizer.normalize(row.input)
            precondition(before != row.expected && after == row.expected, "Regressão não comprovada: \(row.name)")
            regressions.append(["name": row.name, "stage": "number-normalization", "input": row.input, "before": before, "after": after, "expected": row.expected])
        }
        let report: [String: Any] = [
            "baseline_revision": "4daadce01a08c24a884a7d53d6daea539f030617",
            "scope": "post-processing only; synthetic vocabulary; no ASR accuracy or end-to-end latency claim",
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "measurements": measurements, "regressions": regressions
        ]
        print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    }

    static func vocabulary(count: Int) -> [VocabularyEntry] {
        var entries = [
            VocabularyEntry(term: "Claude Code", aliases: ["cloud code"]),
            VocabularyEntry(term: "git pull", aliases: ["git pool"]),
            VocabularyEntry(term: "xcodebuild", aliases: ["x code build"]),
            VocabularyEntry(term: "TypeScript", aliases: ["type script"]),
            VocabularyEntry(term: "PostgreSQL", aliases: ["post gree"])
        ]
        for index in entries.count..<count {
            entries.append(VocabularyEntry(term: "TechnicalTerm\(index)", aliases: ["technical alias \(index)"]))
        }
        return entries
    }
}
