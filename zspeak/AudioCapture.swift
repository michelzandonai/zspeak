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

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return samples.count
    }
}

/// Captura de audio do microfone via AVAudioEngine
/// Converte para 16kHz mono float32 (formato esperado pelo Parakeet TDT)
actor AudioCapture {

    private var engine = AVAudioEngine()
    private let samplesBuffer = SynchronizedBuffer()
    private var isRunning = false
    nonisolated(unsafe) private let converter = AudioConverter()
    nonisolated(unsafe) private var resampleErrors = 0
    private(set) var audioLevel: Float = 0
    private var configObserver: NSObjectProtocol?
    private var currentDeviceUID: String?
    /// Default input device original do HAL, salvo quando trocamos temporariamente.
    /// Restaurado em `stop()` ou em caso de erro durante `start()`.
    private var originalDefaultInputDeviceID: AudioDeviceID?

    var isCapturing: Bool { isRunning }

    /// Inicia captura do microfone, opcionalmente usando um device específico pelo uniqueID
    func start(deviceUID: String? = nil) async throws {
        // Recria engine limpo (necessário após setInputDevice com device incompatível)
        if isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            isRunning = false
        }
        engine = AVAudioEngine()

        samplesBuffer.clear()
        resampleErrors = 0
        currentDeviceUID = deviceUID
        audioLevel = 0

        do {
            try startEngine(deviceUID: deviceUID)
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

    /// Configura e inicia o engine (usado no start e na reconexão)
    /// Sem fallback silencioso: qualquer erro propaga para o chamador decidir.
    /// A camada de orquestração (AppState) é responsável por tentar system default.
    private func startEngine(deviceUID: String?) throws {
        try configureAndStartEngine(deviceUID: deviceUID)
    }

    /// Configura device, instala tap e inicia engine — pode lançar erro
    private func configureAndStartEngine(deviceUID: String?) throws {
        if let uid = deviceUID {
            logger.info("configureAndStartEngine: trocando default input do HAL para \(uid, privacy: .public)")
            try overrideSystemDefaultInput(uniqueID: uid)
        } else {
            logger.info("configureAndStartEngine: usando system default (deviceUID=nil)")
        }

        // Recria engine DEPOIS de trocar o default do HAL — AVAudioEngine()
        // lê o input device atual na primeira inicialização do inputNode, então
        // precisamos garantir que a troca do default já aconteceu.
        engine = AVAudioEngine()

        let inputNode = engine.inputNode
        inputNode.removeTap(onBus: 0)

        let hwFormat = inputNode.outputFormat(forBus: 0)

        guard hwFormat.channelCount > 0, hwFormat.sampleRate > 0 else {
            logger.error("configureAndStartEngine: formato inválido (channels=\(hwFormat.channelCount), sampleRate=\(hwFormat.sampleRate))")
            throw AudioCaptureError.invalidFormat
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
            guard let self else { return }

            if let channelData = buffer.floatChannelData?[0] {
                let frameLength = Int(buffer.frameLength)
                if frameLength > 0 {
                    var sum: Float = 0
                    for i in 0..<frameLength {
                        sum += channelData[i] * channelData[i]
                    }
                    let rms = sqrt(sum / Float(frameLength))
                    let scaledLevel = min(rms * 12.0, 1.0)
                    Task {
                        await self.updateAudioLevel(scaledLevel)
                    }
                }
            }

            do {
                let resampled = try self.converter.resampleBuffer(buffer)
                self.samplesBuffer.append(resampled)
            } catch {
                self.resampleErrors += 1
            }
        }

        engine.prepare()
        try engine.start()
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
        audioLevel = 0

        restoreSystemDefaultInput()

        let result = samplesBuffer.drain()
        return result
    }

    /// Atualiza nível de áudio para feedback visual
    private func updateAudioLevel(_ level: Float) {
        audioLevel = level
    }

    // MARK: - Observação de configuração do engine

    /// Observa mudanças de configuração do AVAudioEngine (device desconectado, route change, etc.)
    /// Remove tap, reinstala com formato atualizado e reinicia o engine
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

        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        isRunning = false
        audioLevel = 0
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
        logger.info("overrideSystemDefaultInput: default atual=\(String(describing: current)) alvo=\(deviceID) uid=\(uniqueID, privacy: .public)")

        if let current, current == deviceID {
            // Já é o default — não precisa restaurar nada
            originalDefaultInputDeviceID = nil
            return
        }

        try setDefaultInputDeviceID(deviceID)
        originalDefaultInputDeviceID = current
        logger.info("overrideSystemDefaultInput: default trocado para deviceID=\(deviceID); original=\(String(describing: current)) salvo para restauração")
    }

    /// Restaura o default input device ao valor salvo em `originalDefaultInputDeviceID`.
    /// Idempotente — no-op se nada foi salvo.
    private func restoreSystemDefaultInput() {
        guard let original = originalDefaultInputDeviceID else { return }
        defer { originalDefaultInputDeviceID = nil }
        do {
            try setDefaultInputDeviceID(original)
            logger.info("restoreSystemDefaultInput: restaurado para deviceID=\(original)")
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
