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

    private var engine = AVAudioEngine()
    private let samplesBuffer = SynchronizedBuffer()
    private var isRunning = false
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
    /// Indica se o engine foi pré-preparado via `warmUp(deviceUID:)`.
    /// Quando true, `start()` pula toda a configuração pesada (criação do
    /// engine, installTap, prepare) e chama apenas `engine.start()` — ganho
    /// de ~200ms na latência total.
    private var isWarmed = false
    /// uniqueID do device usado no warmUp — se divergir do que `start()`
    /// recebe, descartamos o warm e reconfiguramos.
    private var warmedDeviceUID: String?
    /// Callback invocado uma única vez quando o primeiro sample da sessão atual
    /// chega no tap. Usado pelo AppState para transicionar do estado `.preparing`
    /// (overlay com spinner) para `.recording` (overlay com waveform) apenas
    /// quando o engine está de fato capturando áudio.
    private var onFirstSampleCallback: (@Sendable () -> Void)?

    var isCapturing: Bool { isRunning }

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
    /// - Parameter onFirstSample: callback invocado uma única vez quando o primeiro
    ///   buffer de áudio chega no tap. Permite ao chamador sincronizar UI com a
    ///   transição HAL→engine→tap real, eliminando a janela em que o usuário vê
    ///   "gravando" mas nenhuma amostra foi capturada ainda.
    func start(deviceUID: String? = nil, onFirstSample: (@Sendable () -> Void)? = nil) async throws {
        let callTime = CFAbsoluteTimeGetCurrent()

        // Recria engine limpo (necessário após setInputDevice com device incompatível)
        if isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            isRunning = false
        }

        samplesBuffer.clear()
        samplesBuffer.reserveCapacity(Self.expectedMaxCaptureDurationSeconds * Self.targetSampleRate)
        resampleErrors.reset()
        firstSampleScheduled.reset()
        currentDeviceUID = deviceUID
        audioLevelMonitor.reset()
        startCalledTimestamp = callTime
        engineStartTimestamp = nil
        firstSampleTimestamp = nil
        onFirstSampleCallback = onFirstSample

        let canFastPath = isWarmed && warmedDeviceUID == deviceUID
        isWarmed = false

        do {
            if canFastPath {
                // Fast path: engine já foi criado + installTap + prepare no warmUp.
                // Só liga o IO agora — economiza ~200ms de cold setup.
                try engine.start()
                engineStartTimestamp = CFAbsoluteTimeGetCurrent()
            } else {
                engine = AVAudioEngine()
                try startEngine(deviceUID: deviceUID)
            }
        } catch {
            // Garante que o default do sistema volte ao original se a inicialização
            // falhou depois de termos trocado — senão o usuário fica com um default
            // "errado" no macOS após um erro.
            restoreSystemDefaultInput()
            throw error
        }
        observeConfigurationChanges()

        isRunning = true
    }

    /// Pré-prepara o engine com o device indicado SEM abrir o HAL (sem acender
    /// o indicador de microfone nem consumir bateria em captura). Aloca buffers,
    /// instala tap e chama `prepare()`. O próximo `start()` chamado com o mesmo
    /// `deviceUID` pula toda a configuração e invoca apenas `engine.start()`.
    ///
    /// Idempotente: se já aquecido para o mesmo device, retorna imediatamente.
    /// Se aquecido para outro device, descarta e re-aquece.
    func warmUp(deviceUID: String? = nil) async throws {
        // Se já estamos gravando, warmUp seria destrutivo — ignora.
        guard !isRunning else { return }

        // Já aquecido para o device certo: no-op.
        if isWarmed && warmedDeviceUID == deviceUID {
            return
        }

        // Estado anterior (seja aquecido para outro device, seja fresco): limpa.
        if isWarmed {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            isWarmed = false
            restoreSystemDefaultInput()
        }

        if let uid = deviceUID {
            logger.debug("warmUp: trocando default input do HAL para \(uid, privacy: .public)")
            try overrideSystemDefaultInput(uniqueID: uid)
        }

        // Recria engine DEPOIS da troca de HAL (mesmo raciocínio de configureAndStartEngine).
        engine = AVAudioEngine()

        let inputNode = engine.inputNode
        inputNode.removeTap(onBus: 0)

        let hwFormat = inputNode.outputFormat(forBus: 0)
        guard hwFormat.channelCount > 0, hwFormat.sampleRate > 0 else {
            restoreSystemDefaultInput()
            throw AudioCaptureError.invalidFormat
        }

        installTap(on: inputNode)
        engine.prepare()

        // Reinstala o observer de configuração — ele é vinculado ao `engine` via
        // `object:`, e acabamos de recriar o engine. Sem isso, o callback ficaria
        // pendurado no engine antigo e nunca mais dispararia.
        observeConfigurationChanges()

        isWarmed = true
        warmedDeviceUID = deviceUID
        logger.debug("warmUp: engine pré-preparado para deviceUID=\(deviceUID ?? "system-default", privacy: .public)")
    }

    /// Configura e inicia o engine (usado no start e na reconexão)
    /// Sem fallback silencioso: qualquer erro propaga para o chamador decidir.
    /// A camada de orquestração (AppState) é responsável por tentar system default.
    private func startEngine(deviceUID: String?) throws {
        try configureAndStartEngine(deviceUID: deviceUID)
    }

    /// Configura device, instala tap e inicia engine — pode lançar erro
    private func configureAndStartEngine(deviceUID: String?) throws {
        if let uid = deviceUID {
            logger.debug("configureAndStartEngine: trocando default input do HAL para \(uid, privacy: .public)")
            try overrideSystemDefaultInput(uniqueID: uid)
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

        installTap(on: inputNode)

        engine.prepare()
        try engine.start()
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
        let buffer = samplesBuffer
        let levelMonitor = audioLevelMonitor
        let converter = self.converter
        let errors = resampleErrors
        let firstSampleLatch = firstSampleScheduled

        inputNode.installTap(onBus: 0, bufferSize: 512, format: nil) { [weak self] avBuffer, _ in
            let tapTime = CFAbsoluteTimeGetCurrent()

            if let channelData = avBuffer.floatChannelData?[0] {
                let frameLength = Int(avBuffer.frameLength)
                if frameLength > 0 {
                    // Soma dos quadrados via Accelerate (SIMD) — muito mais rápido
                    // que loop Swift puro. A ~94 callbacks/s × 512 frames = ~48k
                    // samples/s de RMS; o loop original era ~5x mais custoso.
                    var sumOfSquares: Float = 0
                    vDSP_svesq(channelData, 1, &sumOfSquares, vDSP_Length(frameLength))
                    let rms = sqrt(sumOfSquares / Float(frameLength))
                    let scaledLevel = min(rms * 12.0, 1.0)
                    // Escrita direta no monitor (lock interno). Sem hop para MainActor,
                    // sem criar Task. A UI faz pull 30 vezes/s.
                    levelMonitor.update(scaledLevel)
                }
            }

            do {
                let resampled = try converter.resampleBuffer(avBuffer)
                buffer.append(resampled)
            } catch {
                errors.increment()
            }

            // Hop único para o actor APENAS no primeiro sample. O latch atômico
            // garante que só UMA Task seja enfileirada por sessão, mesmo que o
            // tap rode ~94 vezes/s. Sem esse latch, cada callback criava uma
            // Task nova que só virava no-op DENTRO do actor — gerando pressão
            // de scheduler que podia atrasar a invocação de onFirstSample e
            // deixar o app preso em "Preparando microfone...".
            if firstSampleLatch.setIfZero(), let self {
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
        let callback = onFirstSampleCallback
        onFirstSampleCallback = nil
        callback?()
    }

    /// Para a captura e retorna todas as amostras acumuladas
    func stop() -> [Float] {
        guard isRunning else {
            restoreSystemDefaultInput()
            return []
        }

        // Remover observer de configuração
        if let observer = configObserver {
            NotificationCenter.default.removeObserver(observer)
            configObserver = nil
        }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        audioLevelMonitor.reset()

        restoreSystemDefaultInput()

        let result = samplesBuffer.drain()
        return result
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
        audioLevelMonitor.reset()
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
    private func overrideSystemDefaultInput(uniqueID: String) throws {
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
