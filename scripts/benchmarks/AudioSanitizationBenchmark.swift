import Darwin
import Foundation

@main
struct AudioSanitizationBenchmark {
    static func main() throws {
        var rows: [[String: Any]] = []
        for seconds in [1, 8, 60, 600, 3_600] {
            let samples = (0..<(seconds * 16_000)).map { index -> Float in
                index % 23 == 0 ? -0.0 : Float(index % 997 - 498) / 500
            }
            let expected = AudioSanitizationReference.sanitize(samples)
            for trial in 0..<9 {
                for baseline in trial % 2 == 0 ? [true, false] : [false, true] {
                    let started = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                    let result = baseline
                        ? AudioSanitizationReference.sanitize(samples)
                        : AudioSampleSanitizer.sanitize(samples)
                    let elapsed = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - started) / 1e6
                    // Consome todo o buffer fora da janela medida: o otimizador
                    // não pode descartar o trabalho nem apenas calcular count.
                    precondition(identical(result, expected), "Sanitização mudou PCM")
                    let sharesBuffer = samples.withUnsafeBufferPointer { input in
                        result.withUnsafeBufferPointer { output in input.baseAddress == output.baseAddress }
                    }
                    rows.append([
                        "name": "valid_pcm_sanitization", "audio_seconds": seconds,
                        "baseline": baseline, "trial": trial, "elapsed_ms": elapsed,
                        "samples_out": result.count, "bit_exact": true,
                        "shares_input_buffer": sharesBuffer,
                        "output_copy_bytes": sharesBuffer ? 0 : result.count * MemoryLayout<Float>.stride,
                    ])
                }
            }
        }
        let report: [String: Any] = [
            "baseline": "AudioFileTranscriber.sanitizeSamples before valid-buffer reuse",
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "quality_gate": "identical_float32_bits", "rows": rows,
        ]
        print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    }

    @inline(never)
    static func identical(_ lhs: [Float], _ rhs: [Float]) -> Bool {
        lhs.withUnsafeBytes { left in rhs.withUnsafeBytes { right in left.elementsEqual(right) } }
    }
}
