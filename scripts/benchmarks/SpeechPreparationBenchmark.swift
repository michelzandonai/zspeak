import Darwin
import Foundation

@main
struct SpeechPreparationBenchmark {
    static func main() throws {
        var rows: [[String: Any]] = []
        for seconds in [1, 8, 60, 600] {
            let samples = (0..<(seconds * 16_000)).map { index -> Float in
                let t = Double(index) / 16_000
                let voice = index % 80_000 < 12_000 ? 0 : 0.012 * sin(t * 2 * .pi * 240)
                return Float(voice + 0.002 * sin(t * 2 * .pi * 25))
            }
            let before = prepare(samples, baseline: true)
            let after = prepare(samples, baseline: false)
            precondition(identical(before, after), "Preparo alterou os samples em \(seconds) s")
            for trial in 0..<7 {
                for baseline in trial % 2 == 0 ? [true, false] : [false, true] {
                    let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                    let result = prepare(samples, baseline: baseline)
                    let elapsed = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / 1e6
                    precondition(identical(result, before), "Pipeline não determinístico")
                    rows.append(["name": "preparation_rms", "audio_seconds": seconds, "baseline": baseline,
                                 "trial": trial, "elapsed_ms": elapsed, "samples_out": result.count, "bit_exact": true])
                    let paddingStart = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                    let padded = baseline
                        ? SpeechPreparationReference.padded(samples, leading: 4_000, trailing: 4_000, minimumCount: 16_000)
                        : AudioSamplePadding.addingSilence(to: samples, leading: 4_000, trailing: 4_000, minimumCount: 16_000)
                    let paddingElapsed = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - paddingStart) / 1e6
                    precondition(padded.count == samples.count + 8_000 && identical(Array(padded[4_000..<(4_000 + samples.count)]), samples))
                    rows.append(["name": "segment_padding", "audio_seconds": seconds, "baseline": baseline,
                                 "trial": trial, "elapsed_ms": paddingElapsed, "samples_out": padded.count, "bit_exact": true])
                }
            }
        }
        let report: [String: Any] = ["baseline_version": "1.0.64", "os": ProcessInfo.processInfo.operatingSystemVersionString,
                                    "rows": rows, "quality_gate": "identical_float32_bits"]
        print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    }

    static func prepare(_ samples: [Float], baseline: Bool) -> [Float] {
        let filtered = baseline ? SpeechPreparationReference.highPassFiltered(samples) : SpeechSignalConditioner.highPassFiltered(samples)
        let trimmed = baseline ? SpeechTrimReference.trimForASR(filtered) : SpeechSampleTrimmer.trimForASR(filtered)
        let normalized = baseline ? SpeechPreparationReference.normalizedLoudness(trimmed.samples) : SpeechSignalConditioner.normalizedLoudness(trimmed.samples)
        let padding = normalized.count <= 8 * 16_000 ? 4_000 : 0
        return baseline ? SpeechPreparationReference.padded(normalized, leading: padding, trailing: padding, minimumCount: 16_000)
                        : AudioSamplePadding.addingSilence(to: normalized, leading: padding, trailing: padding, minimumCount: 16_000)
    }

    static func identical(_ lhs: [Float], _ rhs: [Float]) -> Bool {
        lhs.withUnsafeBytes { left in rhs.withUnsafeBytes { right in left.elementsEqual(right) } }
    }
}
