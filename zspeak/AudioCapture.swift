import Accelerate
import AVFoundation
import CoreAudio
import FluidAudio
import os.log

private let logger = Logger(subsystem: "com.zspeak", category: "AudioCapture")

enum AudioCaptureError: LocalizedError {
    case audioUnitUnavailable
    case coreAudioDeviceNotFound(uid: String)
    case audioUnitSetPropertyFailed(status: OSStatus, uid: String, deviceID: AudioDeviceID)
    case invalidFormat

    var errorDescription: String? {
        switch self {
        case .audioUnitUnavailable:
            return "AudioUnit de entrada não está disponível"
        case .coreAudioDeviceNotFound(let uid):
            return "Device com uniqueID '\(uid)' não encontrado na enumeração do Core Audio"
        case .audioUnitSetPropertyFailed(let status, let uid, let deviceID):
            return "AudioUnitSetProperty falhou (status=\(status)) para uid '\(uid)', deviceID=\(deviceID)"
        case .invalidFormat:
            return "Formato de áudio inválido"
        }
    }
}

/// Contador atômico usado pelo tap (audio render thread) sem lock no hotpath.
/// Substitui `nonisolated(unsafe) var resampleErrors` — que era uma corrida de dados
/// em Swift 6 strict concurrency. OSAtomicIncrement32 foi deprecado; usamos
/// `os_unfair_lock` no wrapper, que é wait-free na prática e safe em qualquer
/// thread (incluindo render thread).
final class AtomicInt: @unchecked Sendable {
    private var value: Int = 0
    private var lock = os_unfair_lock()

    func increment() {
        os_unfair_lock_lock(&lock)
        value &+= 1
        os_unfair_lock_unlock(&lock)
    }

    func reset() {
        os_unfair_lock_lock(&lock)
        value = 0
        os_unfair_lock_unlock(&lock)
    }

    /// Tenta transicionar de 0 → 1 atômico. Retorna `true` se foi quem setou;
    /// `false` se já estava em 1 (ou qualquer outro valor). Usado como latch
    /// "rode isso apenas uma vez" no hotpath do tap, evitando enfileirar
    /// Tasks repetidas no actor a cada buffer (~94 Hz).
    func setIfZero() -> Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard value == 0 else { return false }
        value = 1
        return true
    }

    var current: Int {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return value
    }
}

/// Publica o nível de áudio da gravação de forma thread-safe e reativa.
///
/// Antes, o tap (render thread, ~94 Hz) enfileirava `Task { @MainActor }` a cada
/// buffer só para atualizar uma propriedade no actor `AudioCapture`; a `WaveformView`
/// rodava um `Timer.scheduledTimer(withTimeInterval: 0.033)` que disparava outra
/// `Task { @MainActor }` para `await` o valor. Pipeline de 124+ Tasks/s só para
/// passar um `Float`.
///
/// Agora: tap atualiza `level` sob `os_unfair_lock` (wait-free em caminho sem
/// contenção), e a view lê `currentLevel()` direto, sem hop e sem actor.
/// Opcionalmente expõe como `@Observable` para quem quiser usar observação
/// reativa do SwiftUI — mas `WaveformView` usa `TimelineView(.periodic)` e
/// pull, o que é mais barato que tracking.
final class AudioLevelMonitor: @unchecked Sendable {
    private var _level: Float = 0
    private var lock = os_unfair_lock()

    /// Atualizado pelo tap (render thread). Não aloca, não faz hop.
    func update(_ newLevel: Float) {
        os_unfair_lock_lock(&lock)
        _level = newLevel
        os_unfair_lock_unlock(&lock)
    }

    /// Leitura thread-safe. Usada pela UI (MainActor) e por testes.
    func currentLevel() -> Float {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return _level
    }

    func reset() {
        update(0)
    }
}

/// Flag atômica de 1 bit. Lida pelo tap (render thread) e escrita pelo actor.
/// Usada para decidir, sem hop, se o tap deve alimentar o buffer principal da
/// gravação ou apenas o pre-roll.
final class AtomicBool: @unchecked Sendable {
    private var value: Int = 0
    private var lock = os_unfair_lock()

    var current: Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return value == 1
    }

    func set(_ newValue: Bool) {
        os_unfair_lock_lock(&lock)
        value = newValue ? 1 : 0
        os_unfair_lock_unlock(&lock)
    }
}

/// Ring buffer circular thread-safe para pre-roll de áudio (amostras já no
/// sample rate alvo, 16 kHz mono float32). Enquanto o engine está aberto em
/// modo "hot window", o tap alimenta este buffer continuamente. Quando o
/// usuário dispara uma gravação, as amostras acumuladas são prefixadas ao
/// início da captura — cobrindo o delay entre o atalho e o primeiro sample
/// real. Capacidade fixa: amostras mais antigas são sobrescritas.
final class PreRollBuffer: @unchecked Sendable {
    private let capacity: Int
    private var storage: [Float]
    private var writeIndex: Int = 0
    private var hasWrapped: Bool = false
    private let lock = NSLock()

    init(capacity: Int) {
        self.capacity = max(0, capacity)
        self.storage = [Float](repeating: 0, count: self.capacity)
    }

    func append(_ newSamples: [Float]) {
        guard capacity > 0, !newSamples.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        for sample in newSamples {
            storage[writeIndex] = sample
            writeIndex += 1
            if writeIndex >= capacity {
                writeIndex = 0
                hasWrapped = true
            }
        }
    }

    /// Retorna as amostras em ordem cronológica (mais antiga primeiro).
    func snapshot() -> [Float] {
        guard capacity > 0 else { return [] }
        lock.lock()
        defer { lock.unlock() }
        if !hasWrapped {
            return Array(storage[0..<writeIndex])
        }
        var result = [Float]()
        result.reserveCapacity(capacity)
        result.append(contentsOf: storage[writeIndex..<capacity])
        result.append(contentsOf: storage[0..<writeIndex])
        return result
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        writeIndex = 0
        hasWrapped = false
    }
}

/// Buffer thread-safe para acumular amostras de áudio do tap callback
/// Necessário porque o tap roda na audio render thread, fora do actor
final class SynchronizedBuffer: @unchecked Sendable {
    private var samples: [Float] = []
    private let lock = NSLock()

    func append(_ newSamples: [Float]) {
        lock.lock()
        samples.append(contentsOf: newSamples)
        lock.unlock()
    }

    func drain() -> [Float] {
        lock.lock()
        let result = samples
        samples.removeAll()
        lock.unlock()
        return result
    }

    func clear() {
        lock.lock()
        samples.removeAll()
        lock.unlock()
    }

    /// Pré-aloca capacidade antes de começar a gravar. Evita realocações do
    /// array durante a captura (a 16 kHz, 60 s = 960k Floats = ~3.7 MB). Chamado
    /// uma vez por `start()` — o reset para [] em drain() libera e re-aloca no
    /// próximo start, então este reserveCapacity precisa vir depois de clear()/drain().
    func reserveCapacity(_ capacity: Int) {
        lock.lock()
        samples.reserveCapacity(capacity)
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return samples.count
    }
}

/// Captura de audio do microfone via AVAudioEngine
/// Converte para 16kHz mono float32 (formato esperado pelo Parakeet TDT)
actor AudioCapture {

    /// Upper bound para `reserveCapacity` do buffer de samples: 60 s × 16 kHz.
    /// Gravações maiores seguem funcionando (o array cresce), mas evita realocs
    /// nas gravações normais do usuário (quase sempre < 1 min).
    private static let expectedMaxCaptureDurationSeconds = 60
    private static let targetSampleRate = 16_000

    /// Duração do pre-roll em segundos. 500 ms a 16 kHz = 8 000 samples (~32 KB).
    /// Cobre toda a latência observada entre atalho e primeiro sample real.
    private static let preRollSeconds: Double = 0.5
    /// Tempo para drenar buffers em voo após o stop. Com tap de 512 frames
    /// (~11 ms em 48 kHz), 50 ms cobre callbacks pendentes sem virar pós-roll
    /// perceptível antes da transcrição.
    private static let stopDrainNanoseconds: UInt64 = 50_000_000
    /// Capacidade do ring buffer de pre-roll em samples (16 kHz × 500 ms).
    /// Computado em escopo de tipo para poder ser usado em stored property
    /// initializer — `Self.xxx` é proibido ali em Swift 6.
    private static let preRollCapacity: Int = Int(Double(targetSampleRate) * preRollSeconds)
    /// 250 ms em 16 kHz: reduz chamadas ao streaming ASR sem atrasar a UI.
    private static let liveChunkSampleCount = targetSampleRate / 4

    private var engine = AVAudioEngine()
    private let samplesBuffer = SynchronizedBuffer()
    /// Ring buffer alimentado pelo tap enquanto o engine está aberto em hot window.
    /// Seu conteúdo é prefixado ao início de cada gravação para eliminar perda do
    /// primeiro fonema.
    private let preRollBuffer = PreRollBuffer(capacity: AudioCapture.preRollCapacity)
    private let liveSampleEmitter = LiveSampleEmitter(chunkSampleCount: AudioCapture.liveChunkSampleCount)
    private var isRunning = false
    /// Flag lida pelo tap (render thread) para decidir se alimenta o buffer
    /// principal da gravação. Quando false, o tap apenas alimenta o pre-roll
    /// e NÃO publica nível de áudio — estado "hot window" sem UI de gravação.
    private let isRecordingToMain = AtomicBool()
    /// Converter fica fora do actor para ser chamado direto no tap (render thread).
    /// `AudioConverter` do FluidAudio é thread-safe internamente (confirmado pelo
    /// uso em `AudioFileTranscriber` sem serialização adicional); mantemos a anotação
    /// `nonisolated(unsafe)` até o upstream adicionar `Sendable` ao tipo.
    nonisolated(unsafe) private let converter = AudioConverter()
    /// Contador atômico de erros de resample — incrementado no tap.
    private let resampleErrors = AtomicInt()
    /// Latch atômico usado pelo tap para agendar UMA única `Task` no actor
    /// quando o primeiro sample chega. Sem isso, o tap (~94 Hz) enfileirava
    /// uma Task a cada callback durante toda a gravação. Resetado em `start()`.
    private let firstSampleScheduled = AtomicInt()
    /// Monitor thread-safe de nível de áudio. Compartilhado entre actor (start/stop)
    /// e tap (render thread). Exposto para leitura sincrona via `currentAudioLevel()`.
    nonisolated let audioLevelMonitor = AudioLevelMonitor()
    private var configObserver: NSObjectProtocol?
    private var currentDeviceUID: String?
    /// Default input device original do HAL, salvo quando trocamos temporariamente.
    /// Restaurado em `stop()` ou em caso de erro durante `start()`.
    private var originalDefaultInputDeviceID: AudioDeviceID?
    /// Timestamp (CFAbsoluteTime) do momento em que `start()` foi invocada.
    /// Marca a intenção do usuário — usado para medir latência total até o
    /// primeiro sample chegar (critério que o usuário percebe).
    private(set) var startCalledTimestamp: CFAbsoluteTime?
    /// Timestamp (CFAbsoluteTime) do momento em que `engine.start()` retornou.
    /// Usado para medir a latência até o primeiro buffer de áudio chegar.
    private(set) var engineStartTimestamp: CFAbsoluteTime?
    /// Timestamp do primeiro sample recebido no tap após `engine.start()`.
    /// Permanece nil até o primeiro callback.
    private(set) var firstSampleTimestamp: CFAbsoluteTime?
    /// Indica se há engine em hot window para reuso. O HAL fica aberto, mas o
    /// tap alimenta apenas o pre-roll até o usuário iniciar uma gravação real.
    private var isHotWindowActive = false
    /// uniqueID do device ativo no hot window — se divergir do que `start()`
    /// recebe, descartamos o hot e reconfiguramos.
    private var hotWindowDeviceUID: String?
    /// Timestamp do último `warmUp` concluído com sucesso. Usado pelo
    /// `PerfSignposter` para reportar a idade do prepare (`warmup_age_ms`)
    /// no momento do start — útil para correlacionar fast-path frio vs morno.
    private var lastWarmUpTimestamp: CFAbsoluteTime?
    /// Latch atômico do tap para medir o tempo do PRIMEIRO `resampleBuffer`.
    /// Garante uma única `mark(.firstResample)` por sessão.
    private let firstResampleLogged = AtomicInt()
    /// Interval macro `start_called → first_sample`: aberto em `start()` e
    /// fechado quando o primeiro sample real chega no tap. Reportado pelo
    /// `PerfSignposter` como evento `.startToFirstSample` no log estruturado
    /// (e como signpost no Instruments para visualização gráfica).
    private var startToFirstSampleInterval: PerfSignposter.Interval?
    /// Callback invocado uma única vez quando o primeiro sample da sessão atual
    /// chega no tap. Usado pelo AppState para transicionar do estado `.preparing`
    /// (overlay com spinner) para `.recording` (overlay com waveform) apenas
    /// quando o engine está de fato capturando áudio.
    private var onFirstSampleCallback: (@Sendable () -> Void)?

    var isCapturing: Bool { isRunning }
    /// Exposto para testes/diagnóstico — indica se há engine em hot window.
    var isHot: Bool { isHotWindowActive }

    /// Leitura não-isolated do nível de áudio. Evita hop para o actor no hotpath
    /// da UI (o `WaveformView` faz pull 30 vezes por segundo).
    nonisolated func currentAudioLevel() -> Float {
        audioLevelMonitor.currentLevel()
    }

    /// Mantido para retrocompatibilidade de testes — snapshot sync do nível atual.
    var audioLevel: Float {
        audioLevelMonitor.currentLevel()
    }

    /// Inicia captura do microfone, opcionalmente usando um device específico pelo uniqueID.
    ///
    /// Fast path (modo quente): se o engine já está aberto em hot window para o mesmo
    /// device, `start()` não reabre HAL, não reinstala tap e não chama `engine.start()` —
    /// apenas prefixa o pre-roll acumulado ao buffer principal e liga a flag de
    /// gravação. Latência efetiva: ~0 ms e o primeiro fonema é preservado mesmo se o
    /// usuário falar no mesmo instante em que pressiona o atalho.
    ///
    /// Cold path: engine desligado (ou em device diferente) — sobe o fluxo tradicional.
    ///
    /// - Parameter onFirstSample: callback invocado uma única vez quando a gravação
    ///   começa a persistir samples. No fast path é disparado síncrono (pre-roll já
    ///   existe); no cold path é disparado pelo tap na chegada do primeiro buffer.
    func start(
        deviceUID: String? = nil,
        onFirstSample: (@Sendable () -> Void)? = nil,
        onSamples: (@Sendable ([Float]) -> Void)? = nil
    ) async throws {
        let callTime = CFAbsoluteTimeGetCurrent()

        if isRunning && !isHotWindowActive {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            isRunning = false
        }

        let canReusePrewarm = isRunning && engine.isRunning && isHotWindowActive && hotWindowDeviceUID == deviceUID
        let pathLabel = canReusePrewarm ? "fast" : "cold"
        let deviceChanged = isHotWindowActive && !canReusePrewarm
        let warmupAgeMs = lastWarmUpTimestamp.map { (callTime - $0) * 1000 } ?? -1

        // Metadados base para todos os signposts desta sessão de start().
        let baseMeta: [String: String] = [
            "path": pathLabel,
            "device_changed": String(deviceChanged),
            "warmup_age_ms": warmupAgeMs >= 0 ? String(format: "%.1f", warmupAgeMs) : "n/a"
        ]
        PerfSignposter.mark(.startCalled, metadata: baseMeta)
        // Interval macro: cobre todo o caminho start_called → primeiro sample.
        // Fechado em `markFirstSampleIfNeeded` (acionado pelo tap callback).
        startToFirstSampleInterval = PerfSignposter.begin(.startToFirstSample, metadata: baseMeta)

        if deviceChanged {
            // Device mudou — descarta o prepare em cache.
            tearDownHotWindow()
        }

        let hotPreRoll = canReusePrewarm ? preRollBuffer.snapshot() : []

        samplesBuffer.clear()
        samplesBuffer.reserveCapacity(Self.expectedMaxCaptureDurationSeconds * Self.targetSampleRate)
        resampleErrors.reset()
        firstSampleScheduled.reset()
        firstResampleLogged.reset()
        if !canReusePrewarm {
            preRollBuffer.clear()
        }
        currentDeviceUID = deviceUID
        audioLevelMonitor.reset()
        liveSampleEmitter.reset(onSamples: onSamples)
        startCalledTimestamp = callTime
        engineStartTimestamp = nil
        firstSampleTimestamp = nil
        onFirstSampleCallback = onFirstSample
        isRecordingToMain.set(true)
        isRunning = true

        do {
            if canReusePrewarm {
                // Fast path real: HAL já está aberto desde o warmUp. O clique só
                // promove o hot window para gravação ativa.
                if !hotPreRoll.isEmpty {
                    samplesBuffer.append(hotPreRoll)
                    liveSampleEmitter.append(hotPreRoll)
                }
                preRollBuffer.clear()
                _ = firstSampleScheduled.setIfZero()
                engineStartTimestamp = callTime
                isHotWindowActive = false
                hotWindowDeviceUID = nil
                markFirstSampleIfNeeded(at: callTime)
                logger.info("start: fast path hot window \(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - callTime) * 1000), privacy: .public)ms preRollSamples=\(hotPreRoll.count, privacy: .public)")
            } else {
                engine = AVAudioEngine()
                try startEngine(deviceUID: deviceUID, baseMeta: baseMeta)
                let tEngineStart = engineStartTimestamp ?? CFAbsoluteTimeGetCurrent()
                logger.info("start: cold path \(String(format: "%.1f", (tEngineStart - callTime) * 1000), privacy: .public)ms")
            }
        } catch {
            isRecordingToMain.set(false)
            isRunning = false
            liveSampleEmitter.deactivate()
            restoreSystemDefaultInput()
            throw error
        }

        // Se veio do cold path, precisa instalar observer agora; o warmUp já o
        // instalou (vinculado ao engine atual), então no fast path é no-op
        // evitando remover/reinstalar.
        if !canReusePrewarm {
            observeConfigurationChanges()
        }

        isRunning = true
    }

    /// Pré-aquece o engine mantendo o HAL aberto em modo hot window.
    ///
    /// Ganho: o próximo `start()` no mesmo device não reabre I/O. O tap já está
    /// rodando e alimentando o pre-roll; iniciar gravação só liga a flag que passa
    /// a escrever no buffer principal.
    ///
    /// Idempotente: já preparado para o device certo = no-op.
    /// Device diferente = descarta o prepare anterior e refaz.
    /// Gravação em andamento = ignora (prepare é destrutivo durante captura).
    func warmUp(deviceUID: String? = nil) async throws {
        guard !isRunning || isHotWindowActive else { return }

        if isHotWindowActive && hotWindowDeviceUID == deviceUID {
            return
        }

        if isHotWindowActive {
            tearDownHotWindow()
        }

        let warmMeta: [String: String] = ["scope": "warmup"]

        if let uid = deviceUID {
            logger.debug("warmUp: trocando default input do HAL para \(uid, privacy: .public)")
            try overrideSystemDefaultInput(uniqueID: uid, scope: "warmup")
        }

        engine = AVAudioEngine()
        let inputNode = engine.inputNode
        inputNode.removeTap(onBus: 0)

        let hwFormat = inputNode.outputFormat(forBus: 0)
        guard hwFormat.channelCount > 0, hwFormat.sampleRate > 0 else {
            restoreSystemDefaultInput()
            throw AudioCaptureError.invalidFormat
        }

        preRollBuffer.clear()
        isRecordingToMain.set(false)
        firstSampleScheduled.reset()
        firstResampleLogged.reset()
        let iTap = PerfSignposter.begin(.installTap, metadata: warmMeta)
        installTap(on: inputNode)
        PerfSignposter.end(iTap, metadata: warmMeta)
        let iPrep = PerfSignposter.begin(.enginePrepare, metadata: warmMeta)
        engine.prepare()
        PerfSignposter.end(iPrep, metadata: warmMeta)

        let iStart = PerfSignposter.begin(.engineStart, metadata: warmMeta)
        do {
            try engine.start()
            PerfSignposter.end(iStart, metadata: warmMeta)
            engineStartTimestamp = CFAbsoluteTimeGetCurrent()
        } catch {
            PerfSignposter.end(iStart, metadata: warmMeta)
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            restoreSystemDefaultInput()
            isRunning = false
            isHotWindowActive = false
            hotWindowDeviceUID = nil
            isRecordingToMain.set(false)
            throw error
        }

        observeConfigurationChanges()

        isRunning = true
        isHotWindowActive = true
        hotWindowDeviceUID = deviceUID
        lastWarmUpTimestamp = CFAbsoluteTimeGetCurrent()
        logger.info("warmUp: hot window ativo para deviceUID=\(deviceUID ?? "system-default", privacy: .public)")
    }

    /// Descarta o engine pré-preparado e restaura o default do sistema.
    /// No-op se não havia prepare ativo ou se há gravação em andamento.
    func coolDown() {
        guard isHotWindowActive, !isRecordingToMain.current else { return }
        tearDownHotWindow()
        logger.info("coolDown: prewarm descartado")
    }

    /// Desmontagem efetiva do prepare — compartilhada por `coolDown`, troca
    /// de device em `start()` e `warmUp()`.
    private func tearDownHotWindow() {
        if let observer = configObserver {
            NotificationCenter.default.removeObserver(observer)
            configObserver = nil
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        restoreSystemDefaultInput()
        preRollBuffer.clear()
        liveSampleEmitter.deactivate()
        isHotWindowActive = false
        hotWindowDeviceUID = nil
        isRunning = false
        isRecordingToMain.set(false)
        audioLevelMonitor.reset()
    }

    /// Configura e inicia o engine (usado no start e na reconexão)
    /// Sem fallback silencioso: qualquer erro propaga para o chamador decidir.
    /// A camada de orquestração (AppState) é responsável por tentar system default.
    private func startEngine(deviceUID: String?, baseMeta: [String: String] = [:]) throws {
        try configureAndStartEngine(deviceUID: deviceUID, baseMeta: baseMeta)
    }

    /// Configura device, instala tap e inicia engine — pode lançar erro
    private func configureAndStartEngine(deviceUID: String?, baseMeta: [String: String] = [:]) throws {
        if let uid = deviceUID {
            logger.debug("configureAndStartEngine: trocando default input do HAL para \(uid, privacy: .public)")
            try overrideSystemDefaultInput(uniqueID: uid, scope: "start")
        } else {
            logger.debug("configureAndStartEngine: usando system default (deviceUID=nil)")
        }

        // NB: engine já foi recriado pelo chamador (`start()`), garantindo que
        // nasça alinhado com o default do HAL recém-trocado.

        let inputNode = engine.inputNode
        inputNode.removeTap(onBus: 0)

        let hwFormat = inputNode.outputFormat(forBus: 0)

        guard hwFormat.channelCount > 0, hwFormat.sampleRate > 0 else {
            logger.error("configureAndStartEngine: formato inválido (channels=\(hwFormat.channelCount), sampleRate=\(hwFormat.sampleRate))")
            throw AudioCaptureError.invalidFormat
        }

        let iTap = PerfSignposter.begin(.installTap, metadata: baseMeta)
        installTap(on: inputNode)
        PerfSignposter.end(iTap, metadata: baseMeta)

        let iPrep = PerfSignposter.begin(.enginePrepare, metadata: baseMeta)
        engine.prepare()
        PerfSignposter.end(iPrep, metadata: baseMeta)

        let iStart = PerfSignposter.begin(.engineStart, metadata: baseMeta)
        try engine.start()
        PerfSignposter.end(iStart, metadata: baseMeta)
        engineStartTimestamp = CFAbsoluteTimeGetCurrent()
    }

    /// Instala o tap que alimenta `samplesBuffer` e atualiza `audioLevelMonitor`.
    /// Extraído para ser reutilizado por `configureAndStartEngine` e `warmUp`.
    ///
    /// bufferSize=512 (em vez do default 4096): a 48 kHz, o HAL acumula ~11 ms
    /// de áudio antes do primeiro callback, contra ~85 ms com 4096. Corte direto
    /// de ~74 ms na latência percebida até o primeiro sample chegar. Custo: mais
    /// callbacks/s (~94 vs ~12), cada um ainda é barato (RMS via vDSP + resample).
    private func installTap(on inputNode: AVAudioInputNode) {
        // Capturas nonisolated dos helpers usados pelo tap — evitam cruzar o actor
        // no hotpath (o tap roda na render thread, não no actor).
        let mainBuffer = samplesBuffer
        let ringBuffer = preRollBuffer
        let recordingFlag = isRecordingToMain
        let levelMonitor = audioLevelMonitor
        let converter = self.converter
        let errors = resampleErrors
        let firstSampleLatch = firstSampleScheduled
        let firstResampleLatch = firstResampleLogged
        let liveEmitter = liveSampleEmitter

        inputNode.installTap(onBus: 0, bufferSize: 512, format: nil) { [weak self] avBuffer, _ in
            let tapTime = CFAbsoluteTimeGetCurrent()
            let recording = recordingFlag.current

            // Marca primeiro tap callback durante gravação ativa. Único hop
            // permitido aqui: PerfSignposter aloca String para log; aceitável
            // 1× por sessão (latch setIfZero garante).
            let isFirstSampleOfSession = recording && firstSampleLatch.setIfZero()
            if isFirstSampleOfSession {
                PerfSignposter.mark(.firstTapCallback)
            }

            // Nível de áudio só é publicado durante gravação ativa — evita
            // que a UI (ou qualquer consumidor) veja atividade enquanto o
            // engine está apenas em hot window alimentando o pre-roll.
            if recording, let channelData = avBuffer.floatChannelData?[0] {
                let frameLength = Int(avBuffer.frameLength)
                if frameLength > 0 {
                    var sumOfSquares: Float = 0
                    vDSP_svesq(channelData, 1, &sumOfSquares, vDSP_Length(frameLength))
                    let rms = sqrt(sumOfSquares / Float(frameLength))
                    levelMonitor.update(AudioLevelNormalizer.normalizedRMS(rms))
                }
            }

            // Mede custo do PRIMEIRO resampleBuffer (1× por sessão).
            let measureFirstResample = isFirstSampleOfSession && firstResampleLatch.setIfZero()
            do {
                let resampled: [Float]
                if measureFirstResample {
                    let i = PerfSignposter.begin(.firstResample)
                    resampled = try converter.resampleBuffer(avBuffer)
                    PerfSignposter.end(i)
                } else {
                    resampled = try converter.resampleBuffer(avBuffer)
                }
                // Ring de pre-roll é alimentado SEMPRE que o tap roda — serve
                // tanto para cobrir o gap de abertura quanto para o gap entre
                // gravações consecutivas dentro da mesma hot window.
                ringBuffer.append(resampled)
                if recording {
                    mainBuffer.append(resampled)
                    liveEmitter.append(resampled)
                }
            } catch {
                errors.increment()
            }

            // Hop para o actor apenas UMA vez por sessão de gravação. No fast
            // path (hot window), o latch já foi setado em `start()`, então isso
            // vira no-op. No cold path, marca o primeiro sample real.
            if isFirstSampleOfSession, let self {
                Task { [weak self] in
                    await self?.markFirstSampleIfNeeded(at: tapTime)
                }
            }
        }
    }

    /// Registra o timestamp do primeiro sample recebido após `engine.start()` e
    /// loga a latência. No-op depois do primeiro sample de cada sessão.
    /// Invoca `onFirstSampleCallback` (fora do actor) para notificar o chamador.
    private func markFirstSampleIfNeeded(at timestamp: CFAbsoluteTime) {
        guard firstSampleTimestamp == nil else { return }
        firstSampleTimestamp = timestamp
        if let start = engineStartTimestamp {
            let delayMs = (timestamp - start) * 1000
            logger.info("markFirstSampleIfNeeded: primeiro sample após \(String(format: "%.1f", delayMs), privacy: .public)ms do engine.start()")
        }
        if let interval = startToFirstSampleInterval {
            PerfSignposter.end(interval)
            startToFirstSampleInterval = nil
        }
        let callback = onFirstSampleCallback
        onFirstSampleCallback = nil
        callback?()
    }

    /// Mantém a escrita no buffer principal ativa durante o drain curto.
    /// O tap pode entregar callbacks logo após a hotkey de stop; capturamos esses
    /// buffers em voo, mas não fazemos pós-roll baseado em silêncio para não
    /// atrasar o início da transcrição.
    @discardableResult
    private func drainPendingStopBuffers(
        metadata: [String: String] = [:],
        sleep: (UInt64) async -> Void = { nanoseconds in
            try? await Task.sleep(nanoseconds: nanoseconds)
        }
    ) async -> UInt64 {
        let interval = PerfSignposter.begin(.stopDrain, metadata: metadata)
        await sleep(Self.stopDrainNanoseconds)
        var endMetadata = metadata
        endMetadata["reason"] = "fixed_drain"
        endMetadata["waited_ms"] = String(format: "%.0f", Double(Self.stopDrainNanoseconds) / 1_000_000)
        PerfSignposter.end(interval, metadata: endMetadata)
        isRecordingToMain.set(false)
        return Self.stopDrainNanoseconds
    }

    /// Para a gravação, drena buffers em voo e volta para hot window.
    func stop() async -> [Float] {
        guard isRunning else {
            restoreSystemDefaultInput()
            liveSampleEmitter.deactivate()
            return []
        }

        guard isRecordingToMain.current else {
            liveSampleEmitter.deactivate()
            tearDownHotWindow()
            return []
        }

        await drainPendingStopBuffers(metadata: ["scope": "recording"])

        audioLevelMonitor.reset()

        let result = samplesBuffer.drain()
        liveSampleEmitter.flush()
        liveSampleEmitter.deactivate()
        preRollBuffer.clear()
        isHotWindowActive = true
        hotWindowDeviceUID = currentDeviceUID
        lastWarmUpTimestamp = CFAbsoluteTimeGetCurrent()
        return result
    }

    /// Benchmark determinístico para a regressão do stop sem tocar no HAL.
    /// Simula o tap entregando chunks finais durante o drain curto; todos devem
    /// sobreviver no buffer principal antes de desligarmos a escrita.
    func benchmarkStopDrainPreservesTrailingSamples(iterations: Int) async -> (preservedIterations: Int, elapsedMilliseconds: [Double]) {
        guard iterations > 0 else { return (0, []) }

        let leadingSamples = [Float](repeating: -0.25, count: 160) // 10 ms a 16 kHz.
        let trailingChunk = [Float](repeating: 0.75, count: 80) // 5 ms a 16 kHz.
        let callbacksDuringDrain = 4
        let expectedTrailingSampleCount = trailingChunk.count * callbacksDuringDrain
        let mainBuffer = samplesBuffer
        let recordingFlag = isRecordingToMain
        var preservedIterations = 0
        var elapsedMilliseconds: [Double] = []
        elapsedMilliseconds.reserveCapacity(iterations)

        for _ in 0..<iterations {
            mainBuffer.clear()
            recordingFlag.set(true)
            mainBuffer.append(leadingSamples)

            let startedAt = CFAbsoluteTimeGetCurrent()
            await drainPendingStopBuffers(metadata: ["scope": "benchmark"]) { _ in
                for _ in 0..<callbacksDuringDrain where recordingFlag.current {
                    mainBuffer.append(trailingChunk)
                    await Task.yield()
                }
            }
            elapsedMilliseconds.append((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)

            let samples = mainBuffer.drain()
            if samples.count == leadingSamples.count + expectedTrailingSampleCount,
               samples.suffix(expectedTrailingSampleCount).allSatisfy({ $0 == 0.75 }) {
                preservedIterations += 1
            }
        }

        return (preservedIterations, elapsedMilliseconds)
    }

    // MARK: - Observação de configuração do engine

    /// Observa mudanças de configuração do AVAudioEngine (device desconectado, route change, etc.)
    /// Remove tap, reinstala com formato atualizado e reinicia o engine.
    ///
    /// IMPORTANTE: o observer é vinculado ao `engine` via `object:`, então precisa
    /// ser reinstalado sempre que recriamos o engine (em `start()` cold path e
    /// em `warmUp()`), senão ficaria pendurado no engine antigo e nunca dispararia.
    private func observeConfigurationChanges() {
        if let observer = configObserver {
            NotificationCenter.default.removeObserver(observer)
        }

        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Task {
                await self.handleConfigurationChange()
            }
        }
    }

    /// Para captura graciosamente após mudança de configuração do engine
    /// Não tenta reinstalar tap — installTap lança NSException (não capturável em Swift)
    /// se o formato for incompatível após config change. O fluxo do AppState trata
    /// amostras vazias como "áudio curto" e volta para idle.
    private func handleConfigurationChange() {
        // Se o engine foi derrubado pelo sistema durante hot window (sem
        // gravação ativa), desmonta o hot — a próxima gravação cai no cold
        // path. É mais seguro que tentar reinstalar tap com formato antigo.
        if isHotWindowActive && !isRecordingToMain.current {
            guard !engine.isRunning else {
                logger.debug("handleConfigurationChange: ignorado (hot window ativo e engine rodando)")
                return
            }
            tearDownHotWindow()
            logger.debug("handleConfigurationChange: hot window derrubado pelo HAL, desmontando")
            return
        }

        guard isRunning else { return }

        // Ignorar mudanças ocorridas durante estabilização do engine (antes do
        // primeiro sample chegar no tap). Nesse intervalo o HAL ainda está
        // negociando formato com o device recém-selecionado e dispara
        // `AVAudioEngineConfigurationChange` como parte do setup normal.
        // Parar o engine aqui deixa o app preso em "Preparando microfone..."
        // porque o tap nunca chega a receber o primeiro buffer. Regressão
        // intermitente introduzida na Onda 1 (reinstalação do observer em
        // warmUp expôs mais esses callbacks benignos).
        guard firstSampleTimestamp != nil else {
            logger.debug("handleConfigurationChange: ignorado (pré-primeiro-sample, HAL estabilizando)")
            return
        }

        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        isRunning = false
        isRecordingToMain.set(false)
        audioLevelMonitor.reset()
        if isHotWindowActive {
            isHotWindowActive = false
            hotWindowDeviceUID = nil
            preRollBuffer.clear()
        }
    }

    /// Exposto para testes — simula uma mudança de configuração do engine
    func simulateConfigurationChange() {
        handleConfigurationChange()
    }

    // MARK: - Seleção de device

    /// Troca temporariamente o default input device do HAL para o device desejado.
    /// Salva o default original em `originalDefaultInputDeviceID` para que `stop()`
    /// restaure o estado do sistema.
    ///
    /// Histórico: o caminho anterior manipulava `kAudioOutputUnitProperty_CurrentDevice`
    /// diretamente no `audioUnit` do `engine.inputNode`. Esse padrão sofre do bug
    /// -10868 (`kAudioUnitErr_FormatNotSupported`) no `engine.start()` — o `AUGraphParser`
    /// detecta mismatch entre o formato cacheado do node (lazy-init com o device
    /// anterior) e o HAL recém-trocado, mesmo com `AudioUnitUninitialize`/`Initialize`.
    /// Trocar o default do sistema e deixar o `AVAudioEngine` nascer já com o device
    /// correto evita o mismatch.
    private func overrideSystemDefaultInput(uniqueID: String, scope: String) throws {
        let meta: [String: String] = ["scope": scope]
        let interval = PerfSignposter.begin(.overrideDefaultInput, metadata: meta)
        defer {
            PerfSignposter.end(interval, metadata: meta)
        }

        let deviceID = try findAudioDeviceID(for: uniqueID)
        let current = currentDefaultInputDeviceID()
        logger.debug("overrideSystemDefaultInput: default atual=\(String(describing: current)) alvo=\(deviceID) uid=\(uniqueID, privacy: .public)")

        if let current, current == deviceID {
            // Já é o default — não precisa restaurar nada
            originalDefaultInputDeviceID = nil
            return
        }

        try setDefaultInputDeviceID(deviceID)
        originalDefaultInputDeviceID = current
        logger.debug("overrideSystemDefaultInput: default trocado para deviceID=\(deviceID); original=\(String(describing: current)) salvo para restauração")
    }

    /// Restaura o default input device ao valor salvo em `originalDefaultInputDeviceID`.
    /// Idempotente — no-op se nada foi salvo.
    private func restoreSystemDefaultInput() {
        guard let original = originalDefaultInputDeviceID else { return }
        defer { originalDefaultInputDeviceID = nil }
        do {
            try setDefaultInputDeviceID(original)
            logger.debug("restoreSystemDefaultInput: restaurado para deviceID=\(original)")
        } catch {
            logger.error("restoreSystemDefaultInput: falhou restaurar para deviceID=\(original) erro=\(String(describing: error), privacy: .public)")
        }
    }

    private func currentDefaultInputDeviceID() -> AudioDeviceID? {
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )
        return status == noErr ? deviceID : nil
    }

    private func setDefaultInputDeviceID(_ deviceID: AudioDeviceID) throws {
        var target = deviceID
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, size, &target
        )
        guard status == noErr else {
            logger.error("setDefaultInputDeviceID: falhou status=\(status) deviceID=\(deviceID)")
            throw AudioCaptureError.audioUnitSetPropertyFailed(status: status, uid: "DefaultInputDevice", deviceID: deviceID)
        }
    }

    /// Busca o AudioDeviceID do CoreAudio pelo uniqueID do AVCaptureDevice
    private func findAudioDeviceID(for uniqueID: String) throws -> AudioDeviceID {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress, 0, nil, &dataSize
        )
        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: deviceCount)
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress, 0, nil, &dataSize, &devices
        )

        // Coleta todos os uids encontrados para diagnóstico em caso de miss
        var allFoundUIDs: [String] = []

        for deviceID in devices {
            var uidRef: Unmanaged<CFString>?
            var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let status = withUnsafeMutablePointer(to: &uidRef) { ptr in
                AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, ptr)
            }
            guard status == noErr, let uid = uidRef?.takeUnretainedValue() else { continue }
            let uidString = uid as String
            allFoundUIDs.append(uidString)
            if uidString == uniqueID {
                return deviceID
            }
        }

        // Miss: loga o uid alvo + todos os uids disponíveis no Core Audio
        // para identificar instantaneamente mismatch entre AVFoundation e Core Audio
        logger.error("findAudioDeviceID: uid alvo '\(uniqueID, privacy: .public)' NÃO encontrado. UIDs do Core Audio: \(allFoundUIDs.joined(separator: ", "), privacy: .public)")
        throw AudioCaptureError.coreAudioDeviceNotFound(uid: uniqueID)
    }
}
