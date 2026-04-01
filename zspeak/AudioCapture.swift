import AVFoundation
import CoreAudio
import FluidAudio

enum AudioCaptureError: LocalizedError {
    case deviceNotFound
    var errorDescription: String? { "Dispositivo de áudio não encontrado" }
}

/// Captura de audio do microfone via AVAudioEngine
/// Converte para 16kHz mono float32 (formato esperado pelo Parakeet TDT)
actor AudioCapture {

    private let engine = AVAudioEngine()
    private var samples: [Float] = []
    private var isRunning = false
    nonisolated(unsafe) private let converter = AudioConverter()
    private(set) var audioLevel: Float = 0

    var isCapturing: Bool { isRunning }

    /// Inicia captura do microfone, opcionalmente usando um device específico pelo uniqueID
    func start(deviceUID: String? = nil) async throws {
        guard !isRunning else { return }

        samples.removeAll()

        // Configurar device específico antes de acessar inputNode
        if let uid = deviceUID {
            try setInputDevice(uniqueID: uid)
        }

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // installTap captura audio bruto do microfone
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }

            // Calcular nível de áudio (RMS) para feedback visual
            if let channelData = buffer.floatChannelData?[0] {
                let frameLength = Int(buffer.frameLength)
                var sum: Float = 0
                for i in 0..<frameLength {
                    sum += channelData[i] * channelData[i]
                }
                let rms = sqrt(sum / Float(frameLength))
                // Escalar para 0-1 com alta sensibilidade (voz normal ~0.02-0.1 RMS)
                let scaledLevel = min(rms * 12.0, 1.0)
                Task {
                    await self.updateAudioLevel(scaledLevel)
                }
            }

            // Converte para 16kHz mono float32 usando FluidAudio AudioConverter
            if let resampled = try? self.converter.resampleBuffer(buffer) {
                Task {
                    await self.appendSamples(resampled)
                }
            }
        }

        engine.prepare()
        try engine.start()
        isRunning = true
    }

    /// Para a captura e retorna todas as amostras acumuladas
    func stop() -> [Float] {
        guard isRunning else { return [] }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false

        let result = samples
        samples.removeAll()
        return result
    }

    /// Atualiza nível de áudio para feedback visual
    private func updateAudioLevel(_ level: Float) {
        audioLevel = level
    }

    /// Acumula amostras no buffer (chamado pelo tap callback)
    private func appendSamples(_ newSamples: [Float]) {
        samples.append(contentsOf: newSamples)
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
