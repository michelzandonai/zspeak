import AVFoundation
import FluidAudio

/// Captura de audio do microfone via AVAudioEngine
/// Converte para 16kHz mono float32 (formato esperado pelo Parakeet TDT)
actor AudioCapture {

    private let engine = AVAudioEngine()
    private var samples: [Float] = []
    private var isRunning = false
    private let converter = AudioConverter()

    var isCapturing: Bool { isRunning }

    /// Inicia captura do microfone
    func start() async throws {
        guard !isRunning else { return }

        samples.removeAll()

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // installTap captura audio bruto do microfone
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }

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

    /// Acumula amostras no buffer (chamado pelo tap callback)
    private func appendSamples(_ newSamples: [Float]) {
        samples.append(contentsOf: newSamples)
    }
}
