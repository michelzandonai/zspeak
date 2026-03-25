import FluidAudio

/// Wrapper para Voice Activity Detection usando Silero VAD via FluidAudio
/// Detecta início e fim de fala para evitar alucinação em silêncio
actor VADManagerWrapper {

    private var vadManager: VadManager?
    private var streamState: VadStreamState?

    /// Inicializa o modelo Silero VAD (auto-download)
    func initialize() async throws {
        let config = VadConfig(defaultThreshold: 0.75)
        let manager = try await VadManager(config: config)
        self.vadManager = manager
        self.streamState = await manager.makeStreamState()
    }

    /// Resultado de um chunk processado pelo VAD
    enum VADEvent {
        case speechStart
        case speechEnd
    }

    /// Processa um chunk de áudio e retorna evento se houver mudança de estado
    /// Chunks devem ter VadManager.chunkSize (4096) samples
    func processChunk(_ samples: [Float]) async throws -> VADEvent? {
        guard let manager = vadManager, var state = streamState else {
            return nil
        }

        let result = try await manager.processStreamingChunk(
            samples,
            state: state,
            config: .default,
            returnSeconds: true,
            timeResolution: 2
        )

        self.streamState = result.state

        guard let event = result.event else {
            return nil
        }

        switch event.kind {
        case .speechStart:
            return .speechStart
        case .speechEnd:
            return .speechEnd
        }
    }

    /// Reseta o estado do VAD para nova sessão
    func reset() async {
        guard let manager = vadManager else { return }
        self.streamState = await manager.makeStreamState()
    }
}
