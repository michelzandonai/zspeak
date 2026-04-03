import AVFoundation
import CoreAudio
import FluidAudio

enum AudioCaptureError: LocalizedError {
    case deviceNotFound
    case invalidFormat
    var errorDescription: String? {
        switch self {
        case .deviceNotFound: "Dispositivo de áudio não encontrado"
        case .invalidFormat: "Formato de áudio inválido"
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

    private let engine = AVAudioEngine()
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
        guard !isRunning else { return }

        samplesBuffer.clear()
        resampleErrors = 0
        currentDeviceUID = deviceUID

        try startEngine(deviceUID: deviceUID)
        observeConfigurationChanges()

        isRunning = true
        print("[zspeak] AudioCapture iniciado")
    }

    /// Configura e inicia o engine (usado no start e na reconexão)
    private func startEngine(deviceUID: String?) throws {
        // Configurar device específico antes de acessar inputNode
        if let uid = deviceUID {
            try setInputDevice(uniqueID: uid)
        }

        let inputNode = engine.inputNode

        // outputFormat é o formato real que o inputNode entrega ao tap
        let hwFormat = inputNode.outputFormat(forBus: 0)
        // Fallback para 44100 se sampleRate for 0 (device ainda sendo configurado)
        let sampleRate = hwFormat.sampleRate > 0 ? hwFormat.sampleRate : 44100.0
        print("[zspeak] AudioCapture formato: \(sampleRate)Hz, \(hwFormat.channelCount)ch")

        guard let tapFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioCaptureError.invalidFormat
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { [weak self] buffer, _ in
            guard let self else { return }

            // Calcular nível de áudio (RMS) para feedback visual
            if let channelData = buffer.floatChannelData?[0] {
                let frameLength = Int(buffer.frameLength)
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

            // Converte para 16kHz mono float32 usando FluidAudio AudioConverter
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

    /// Tenta reiniciar o engine após mudança de configuração
    /// Remove o tap e reinstala via startEngine para garantir formato compatível com novo device
    private func handleConfigurationChange() {
        guard isRunning else { return }

        print("[zspeak] Config change detectado, reinstalando tap e reiniciando engine...")

        // Parar engine e remover tap existente (seguro mesmo se não há tap)
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)

        do {
            try startEngine(deviceUID: currentDeviceUID)
            print("[zspeak] Engine reiniciado com sucesso após config change")
        } catch {
            print("[zspeak] ❌ Falha ao reiniciar engine: \(error)")
            isRunning = false
        }
    }

    /// Exposto para testes — simula uma mudança de configuração do engine
    func simulateConfigurationChange() {
        handleConfigurationChange()
    }

    // MARK: - Seleção de device

    /// Configura o AVAudioEngine para usar um device de input específico
    private func setInputDevice(uniqueID: String) throws {
        let audioUnit = engine.inputNode.audioUnit!
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
            var uid: CFString = "" as CFString
            var uidSize = UInt32(MemoryLayout<CFString>.size)
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, &uid)
            if uid as String == uniqueID {
                return deviceID
            }
        }
        throw AudioCaptureError.deviceNotFound
    }
}
