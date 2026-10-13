import AVFoundation
import Darwin
import Foundation

// Compila os arquivos reais do pipeline com -O, sem inicializar ASR ou interface.
// O tempo simulado permite medir gravações longas sem esperar dez minutos.
@main
struct CaptureBenchmark {
    static func main() throws {
        let arguments = CommandLine.arguments
        func option(_ name: String, fallback: Int) -> Int {
            guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count,
                  let value = Int(arguments[index + 1]), value > 0 else { return fallback }
            return value
        }
        let seconds = option("--seconds", fallback: 600)
        let trials = option("--trials", fallback: 5)
        var rows: [[String: Any]] = []
        for trial in 0..<trials {
            rows.append(try resampling(seconds: seconds, trial: trial))
            rows.append(mixing(seconds: seconds, trial: trial))
            rows.append(emittingBurst(seconds: 30, trial: trial))
        }
        let report: [String: Any] = [
            "seconds": seconds, "trials": trials,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "processors": ProcessInfo.processInfo.processorCount,
            "memory_bytes": ProcessInfo.processInfo.physicalMemory,
            "rows": rows
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }

    static func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))]
    }

    static func row(_ name: String, trial: Int, start: UInt64, seconds: Double, timings: [Double], samples: Int) -> [String: Any] {
        let elapsed = Double(now() - start) / 1_000_000
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return [
            "name": name, "trial": trial, "elapsed_ms": elapsed,
            "audio_seconds": seconds, "samples": samples,
            "p50_callback_us": percentile(timings, 0.5),
            "p95_callback_us": percentile(timings, 0.95),
            "max_callback_us": timings.max()!,
            "peak_process_bytes": usage.ru_maxrss
        ]
    }

    static func resampling(seconds: Int, trial: Int) throws -> [String: Any] {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
        let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
        input.frameLength = 512
        for channel in 0..<2 {
            for frame in 0..<512 { input.floatChannelData![channel][frame] = Float(sin(Double(frame) * 0.05)) * 0.25 }
        }
        let resampler = StreamingResampler()
        _ = try resampler.process(input) // negociação do formato fora do regime contínuo
        let iterations = seconds * 48_000 / 512
        var count = 0
        var energy = 0.0
        var timings: [Double] = []
        timings.reserveCapacity(iterations)
        let start = now()
        for _ in 0..<iterations {
            let before = now()
            let samples = try resampler.process(input)
            count += samples.count
            // Consome o sinal para que -O não possa medir apenas o tamanho
            // do array e eliminar o trabalho de materialização dos samples.
            for sample in samples { energy += Double(sample) * Double(sample) }
            timings.append(Double(now() - before) / 1_000)
        }
        precondition(abs(count - iterations * 512 / 3) < 1_600, "Conversão perdeu samples")
        precondition(energy.isFinite && energy / Double(count) > 0.001 && energy / Double(count) < 0.1, "Conversão perdeu o sinal")
        var result = row("resample_stereo_48k", trial: trial, start: start, seconds: Double(iterations * 512) / 48_000, timings: timings, samples: count)
        result["signal_energy"] = energy
        return result
    }

    static func mixing(seconds: Int, trial: Int) -> [String: Any] {
        let origin = 10.0
        let mixer = AudioTimelineMixer(origin: origin)
        let emitter = LiveSampleEmitter(chunkSampleCount: 4_000)
        let counter = SampleCounter()
        emitter.reset { counter.add($0) }
        let input = [Float](repeating: 0.25, count: 160)
        let iterations = seconds * 100
        var timings: [Double] = []
        timings.reserveCapacity(iterations)
        let start = now()
        for index in 0..<iterations {
            let before = now()
            let timestamp = origin + Double(index) / 100
            mixer.append(TimestampedAudioChunk(startTime: timestamp, samples: input))
            mixer.append(TimestampedAudioChunk(startTime: timestamp, samples: input))
            if index % 5 == 0 { emitter.append(mixer.takeReady(upTo: timestamp - 0.25)) }
            timings.append(Double(now() - before) / 1_000)
        }
        let stopStart = now()
        let final = mixer.finish()
        let stopMilliseconds = Double(now() - stopStart) / 1_000_000
        emitter.append(final.remainingLiveSamples)
        emitter.flush()
        precondition(final.samples.count == seconds * 16_000 && counter.count == final.samples.count, "Perda/duplicação no áudio final ou ao vivo")
        precondition(counter.sum == Double(final.samples.count) * 0.25, "Emissão alterou o sinal")
        precondition(final.samples.allSatisfy { $0 == 0.25 }, "Mistura alterou o sinal")
        var result = row("mixed_two_sources", trial: trial, start: start, seconds: Double(seconds), timings: timings, samples: final.samples.count)
        result["stop_ms"] = stopMilliseconds
        if CommandLine.arguments.contains("--check") {
            // Margem ampla para Apple Silicon; evita gates baseados no pior
            // caso isolado, que pode incluir uma preempção do sistema.
            precondition(percentile(timings, 0.95) < 1_000, "p95 excedeu 1 ms por bloco de 10 ms")
            precondition((result["elapsed_ms"] as! Double) < Double(seconds) * 10, "Mistura consumiu mais de 1% do tempo real")
        }
        return result
    }

    static func emittingBurst(seconds: Int, trial: Int) -> [String: Any] {
        let emitter = LiveSampleEmitter(chunkSampleCount: 4_000)
        let counter = SampleCounter()
        emitter.reset { counter.add($0) }
        let input = [Float](repeating: 0.25, count: seconds * 16_000)
        let start = now()
        emitter.append(input)
        emitter.flush()
        let elapsed = Double(now() - start) / 1_000
        precondition(counter.count == input.count, "Emissão perdeu samples")
        precondition(counter.sum == Double(input.count) * 0.25, "Emissão alterou o sinal")
        return row("live_burst_30s", trial: trial, start: start, seconds: Double(seconds), timings: [elapsed], samples: counter.count)
    }
}

private final class SampleCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    private var checksum = 0.0
    var count: Int { lock.withLock { value } }
    var sum: Double { lock.withLock { checksum } }
    func add(_ samples: [Float]) {
        let sum = samples.reduce(0.0) { $0 + Double($1) }
        lock.withLock { value += samples.count; checksum += sum }
    }
}
