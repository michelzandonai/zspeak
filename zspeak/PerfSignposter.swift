import Foundation
import os
import os.log

/// Instrumentação de latência do pipeline de captura.
///
/// Combina `os_signpost` (visível em Instruments → Points of Interest) com
/// `Logger` estruturado (parseável por `scripts/perf_audio_bench.sh` via
/// `log show --predicate 'subsystem == "com.zspeak" AND category == "PerfAudio"'`).
///
/// Formato dos logs:
/// ```
/// PERF event=engine_start phase=end elapsed_ms=42.31 path=fast device_changed=false
/// ```
///
/// Uso típico (intervalo síncrono):
/// ```swift
/// let i = PerfSignposter.begin(.engineStart, metadata: ["path": "fast"])
/// try engine.start()
/// PerfSignposter.end(i)
/// ```
///
/// Uso para evento pontual:
/// ```swift
/// PerfSignposter.mark(.hotkey, metadata: ["state": "idle"])
/// ```
enum PerfSignposter {
    private static let subsystem = "com.zspeak"
    private static let category = "PerfAudio"

    private static let logger = Logger(subsystem: subsystem, category: category)
    private static let signposter = OSSignposter(subsystem: subsystem, category: category)

    /// Eventos instrumentados no pipeline hotkey → primeiro sample.
    /// O `rawValue` aparece no log estruturado e nos signposts.
    enum Event: String, Sendable {
        /// Hotkey detectada (t0).
        case hotkey
        /// Entrada em `AudioCapture.start`.
        case startCalled = "start_called"
        /// Property set do default input do HAL.
        case overrideDefaultInput = "override_default_input"
        /// Instalação do tap no inputNode.
        case installTap = "install_tap"
        /// `engine.prepare()` (cold path).
        case enginePrepare = "engine_prepare"
        /// `engine.start()` — abre o HAL.
        case engineStart = "engine_start"
        /// Primeiro callback do tap (HAL entregou o 1º buffer).
        case firstTapCallback = "first_tap_callback"
        /// Primeiro `resampleBuffer` no tap (custo do AudioConverter no 1º buffer).
        case firstResample = "first_resample"
        /// Callback `onFirstSample` chegou ao controller (t3).
        case firstSampleCallback = "first_sample_callback"
        /// Sessão completa: `start_called` → `first_sample_callback` (intervalo macro).
        case startToFirstSample = "start_to_first_sample"
        /// Janela de drain no stop, mantendo a escrita ativa para capturar o fim.
        case stopDrain = "stop_drain"
        /// Tempo gasto dentro do ASR Parakeet.
        case asrTranscribe = "asr_transcribe"
    }

    /// Handle de um intervalo aberto. Sendable para atravessar actor boundaries
    /// (tap callback → actor, etc.).
    struct Interval: Sendable {
        let event: Event
        /// Nanosegundos monotônicos (CLOCK_UPTIME_RAW) — imune a saltos de
        /// NTP/mudança de relógio que corrompiam o `elapsed_ms` do log.
        let startUptimeNanos: UInt64
        let signpostID: OSSignpostID
        let signpostState: OSSignpostIntervalState
    }

    // MARK: - API

    /// Marca um evento pontual (sem duração). Útil para "primeiro sample chegou agora".
    static func mark(_ event: Event, metadata: [String: String] = [:]) {
        emitSignpostEvent(event)
        log(event: event, phase: "mark", metadata: metadata)
    }

    /// Abre um intervalo. Devolve handle para fechar com `end(_:)`.
    static func begin(_ event: Event, metadata: [String: String] = [:]) -> Interval {
        let id = signposter.makeSignpostID()
        let state = beginSignpost(event, id: id)
        log(event: event, phase: "begin", metadata: metadata)
        return Interval(
            event: event,
            startUptimeNanos: clock_gettime_nsec_np(CLOCK_UPTIME_RAW),
            signpostID: id,
            signpostState: state
        )
    }

    /// Fecha um intervalo aberto por `begin`. Calcula `elapsed_ms` e adiciona ao log.
    static func end(_ interval: Interval, metadata: [String: String] = [:]) {
        let elapsedNanos = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) &- interval.startUptimeNanos
        let elapsedMs = Double(elapsedNanos) / 1_000_000
        endSignpost(interval.event, state: interval.signpostState)
        var meta = metadata
        meta["elapsed_ms"] = String(format: "%.2f", elapsedMs)
        log(event: interval.event, phase: "end", metadata: meta)
    }

    /// Mede um bloco síncrono.
    static func measure<T>(_ event: Event, metadata: [String: String] = [:], _ block: @Sendable () throws -> T) rethrows -> T {
        let i = begin(event, metadata: metadata)
        defer { end(i) }
        return try block()
    }

    /// Mede um bloco assíncrono.
    static func measure<T>(_ event: Event, metadata: [String: String] = [:], _ block: @Sendable () async throws -> T) async rethrows -> T {
        let i = begin(event, metadata: metadata)
        defer { end(i) }
        return try await block()
    }

    // MARK: - Implementação

    private static func log(event: Event, phase: String, metadata: [String: String]) {
        var parts = ["PERF event=\(event.rawValue) phase=\(phase)"]
        for key in metadata.keys.sorted() {
            parts.append("\(key)=\(metadata[key]!)")
        }
        let line = parts.joined(separator: " ")
        logger.info("\(line, privacy: .public)")
    }

    /// `OSSignposter.beginInterval` exige `StaticString`; mapeamos via switch
    /// para cada evento. Mantém o trace utilizável no Instruments.
    private static func beginSignpost(_ event: Event, id: OSSignpostID) -> OSSignpostIntervalState {
        switch event {
        case .hotkey: return signposter.beginInterval("hotkey", id: id)
        case .startCalled: return signposter.beginInterval("start_called", id: id)
        case .overrideDefaultInput: return signposter.beginInterval("override_default_input", id: id)
        case .installTap: return signposter.beginInterval("install_tap", id: id)
        case .enginePrepare: return signposter.beginInterval("engine_prepare", id: id)
        case .engineStart: return signposter.beginInterval("engine_start", id: id)
        case .firstTapCallback: return signposter.beginInterval("first_tap_callback", id: id)
        case .firstResample: return signposter.beginInterval("first_resample", id: id)
        case .firstSampleCallback: return signposter.beginInterval("first_sample_callback", id: id)
        case .startToFirstSample: return signposter.beginInterval("start_to_first_sample", id: id)
        case .stopDrain: return signposter.beginInterval("stop_drain", id: id)
        case .asrTranscribe: return signposter.beginInterval("asr_transcribe", id: id)
        }
    }

    private static func endSignpost(_ event: Event, state: OSSignpostIntervalState) {
        switch event {
        case .hotkey: signposter.endInterval("hotkey", state)
        case .startCalled: signposter.endInterval("start_called", state)
        case .overrideDefaultInput: signposter.endInterval("override_default_input", state)
        case .installTap: signposter.endInterval("install_tap", state)
        case .enginePrepare: signposter.endInterval("engine_prepare", state)
        case .engineStart: signposter.endInterval("engine_start", state)
        case .firstTapCallback: signposter.endInterval("first_tap_callback", state)
        case .firstResample: signposter.endInterval("first_resample", state)
        case .firstSampleCallback: signposter.endInterval("first_sample_callback", state)
        case .startToFirstSample: signposter.endInterval("start_to_first_sample", state)
        case .stopDrain: signposter.endInterval("stop_drain", state)
        case .asrTranscribe: signposter.endInterval("asr_transcribe", state)
        }
    }

    private static func emitSignpostEvent(_ event: Event) {
        switch event {
        case .hotkey: signposter.emitEvent("hotkey")
        case .startCalled: signposter.emitEvent("start_called")
        case .overrideDefaultInput: signposter.emitEvent("override_default_input")
        case .installTap: signposter.emitEvent("install_tap")
        case .enginePrepare: signposter.emitEvent("engine_prepare")
        case .engineStart: signposter.emitEvent("engine_start")
        case .firstTapCallback: signposter.emitEvent("first_tap_callback")
        case .firstResample: signposter.emitEvent("first_resample")
        case .firstSampleCallback: signposter.emitEvent("first_sample_callback")
        case .startToFirstSample: signposter.emitEvent("start_to_first_sample")
        case .stopDrain: signposter.emitEvent("stop_drain")
        case .asrTranscribe: signposter.emitEvent("asr_transcribe")
        }
    }
}
