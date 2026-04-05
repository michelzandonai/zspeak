import AVFoundation
import CoreAudio
import FluidAudio

enum AudioCaptureError: LocalizedError {
    case deviceNotFound
    case invalidFormat
    case audioUnitUnavailable
    var errorDescription: String? {
        switch self {
        case .deviceNotFound: "Dispositivo de áudio não encontrado"
        case .invalidFormat: "Formato de áudio inválido"
        case .audioUnitUnavailable: "AudioUnit de entrada não está disponível"
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

        try startEngine(deviceUID: deviceUID)
        observeConfigurationChanges()

        isRunning = true
        print("[zspeak] AudioCapture iniciado")
    }

    /// Configura e inicia o engine (usado no start e na reconexão)
    private func startEngine(deviceUID: String?) throws {
        do {
            try configureAndStartEngine(deviceUID: deviceUID)
        } catch {
            // Se falhou com device específico, tenta fallback pro system default
            if deviceUID != nil {
                print("[zspeak] ⚠️ Falha com device \(deviceUID ?? "?"), tentando system default: \(error.localizedDescription)")
                engine.stop()
                engine.inputNode.removeTap(onBus: 0)
                engine.reset()
                currentDeviceUID = nil
                try configureAndStartEngine(deviceUID: nil)
                return
            }
            throw error
        }
    }

    /// Configura device, instala tap e inicia engine — pode lançar erro
    private func configureAndStartEngine(deviceUID: String?) throws {
        if let uid = deviceUID {
            try setInputDevice(uniqueID: uid)
        }

        let inputNode = engine.inputNode
        inputNode.removeTap(onBus: 0)

        let hwFormat = inputNode.outputFormat(forBus: 0)
        print("[zspeak] AudioCapture formato do hardware: \(hwFormat.sampleRate)Hz, \(hwFormat.channelCount)ch")

        guard hwFormat.channelCount > 0, hwFormat.sampleRate > 0 else {
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
                print("[zspeak] ❌ Erro no resampleBuffer (#\(self.resampleErrors)): \(error)")
            }
        }

        engine.prepare()
        try engine.start()
    }

    /// Para a captura e retorna todas as amostras acumuladas
    func stop() -> [Float] {
        guard isRunning else { return [] }

        // Remover observer de configuração
        if let observer = configObserver {
            NotificationCenter.default.removeObserver(observer)
            configObserver = nil
        }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        audioLevel = 0

        let result = samplesBuffer.drain()
        let duration = Float(result.count) / 16000.0
        print("[zspeak] AudioCapture.stop(): \(result.count) samples (\(String(format: "%.1f", duration))s)")
        if resampleErrors > 0 {
            print("[zspeak] ⚠️ \(resampleErrors) erros de resample durante gravação")
        }
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
            print("[zspeak] AVAudioEngine configuração mudou")
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

        print("[zspeak] Config change detectado, parando captura graciosamente...")

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

    /// Configura o AVAudioEngine para usar um device de input específico
    private func setInputDevice(uniqueID: String) throws {
        guard let audioUnit = engine.inputNode.audioUnit else {
            throw AudioCaptureError.audioUnitUnavailable
        }
        var deviceID = try findAudioDeviceID(for: uniqueID)
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            size
        )
        guard status == noErr else {
            throw AudioCaptureError.deviceNotFound
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
            if uid as String == uniqueID {
                return deviceID
            }
        }
        throw AudioCaptureError.deviceNotFound
    }
}
