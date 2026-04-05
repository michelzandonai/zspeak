import SwiftUI
import FluidAudio
import os.log

private let logger = Logger(subsystem: "com.zspeak", category: "AppState")

/// Estado global da aplicacao — controla o fluxo de gravacao e transcricao
@MainActor
@Observable
final class AppState {

    // MARK: - Estado

    enum RecordingState {
        case idle          // Pronto para usar
        case recording     // Gravando audio
        case processing    // Transcrevendo
    }

    var state: RecordingState = .idle
    var lastTranscription: String = ""
    var isModelReady: Bool = false
    var errorMessage: String?
    /// Estado da permissão de acessibilidade — setado externamente pelo App.swift
    var accessibilityGranted: Bool = false
    /// Store para persistir histórico de transcrições — setado externamente pelo App.swift
    var store: TranscriptionStore?
    /// Store de benchmark — setado externamente pelo App.swift
    var benchmarkStore: BenchmarkStore?
    /// Store de vocabulário customizado — setado externamente pelo App.swift
    var vocabularyStore: VocabularyStore?

    // MARK: - Dependencias

    let microphoneManager: MicrophoneManager
    private let audioCapture = AudioCapture()
    private let vadManager = VADManagerWrapper()
    private let transcriber = Transcriber()
    private let textInserter = TextInserter()

    /// Expõe transcrição para uso externo (benchmark)
    func transcribe(_ samples: [Float]) async throws -> String {
        try await transcriber.transcribe(samples)
    }

    /// Aplica vocabulário customizado ao Transcriber (context biasing nativo)
    func applyVocabulary() async throws {
        guard let store = vocabularyStore else { return }
        let enabledEntries = store.entries.filter(\.isEnabled)
        if enabledEntries.isEmpty {
            await transcriber.disableVocabulary()
        } else {
            let context = store.buildVocabularyContext()
            try await transcriber.configureVocabulary(context)
        }
    }
    private var recordingTask: Task<Void, Never>?
    private var isRequestingMicrophonePermission = false

    init(skipBundlePermissionCheck: Bool = false) {
        self.microphoneManager = MicrophoneManager(skipBundlePermissionCheck: skipBundlePermissionCheck)
    }

    /// Lê nível de áudio direto do AudioCapture (usado pelo WaveformView)
    func currentAudioLevel() async -> Float {
        await audioCapture.audioLevel
    }

    // MARK: - Inicializacao

    /// Carrega modelos (ASR + VAD) — chamado no startup do app
    func initialize() async {
        do {
            // Carrega modelos em paralelo
            async let asrInit: () = transcriber.initialize()
            async let vadInit: () = vadManager.initialize()
            try await asrInit
            try await vadInit
            isModelReady = true

            // Aplica vocabulário customizado se configurado
            try? await applyVocabulary()
        } catch {
            errorMessage = "Erro ao carregar modelos: \(error.localizedDescription)"
        }
    }

    // MARK: - Toggle de gravacao

    /// Alterna entre gravar e parar — chamado pela hotkey
    func toggleRecording() {
        logger.info("toggleRecording: estado atual = \(String(describing: self.state))")
        switch state {
        case .idle:
            startRecording()
        case .recording:
            stopRecording()
        case .processing:
            logger.info("toggleRecording: ignorado durante processing")
        }
    }

    /// Inicia gravação se estiver idle — usado pelo modo Hold
    func startRecordingIfIdle() {
        guard state == .idle else { return }
        startRecording()
    }

    /// Para gravação se estiver gravando — usado pelo modo Hold
    func stopRecordingIfActive() {
        guard state == .recording else { return }
        stopRecording()
    }

    /// Cancela gravação em andamento — usado pelo Escape
    func cancelRecording() {
        guard state == .recording else { return }
        print("[zspeak] Gravação cancelada pelo usuário")
        state = .idle
        Task {
            await recordingTask?.value
            recordingTask = nil
            _ = await audioCapture.stop()
        }
    }

    // MARK: - Gravacao

    private func startRecording() {
        guard isModelReady else {
            logger.error("startRecording: modelo não pronto")
            errorMessage = "Modelo ainda carregando, aguarde..."
            return
        }

        microphoneManager.refreshPermissionState()
        logger.info("startRecording: permissão mic = \(self.microphoneManager.permissionState == .authorized ? "OK" : "NEGADA", privacy: .public)")
        guard microphoneManager.isPermissionGranted else {
            logger.error("startRecording: sem permissão de microfone, estado = \(String(describing: self.microphoneManager.permissionState))")
            resolveMicrophonePermission()
            return
        }

        state = .recording
        errorMessage = nil
        TextInserter.saveFocusedApp()
        logger.info("startRecording: estado → recording")

        recordingTask = Task {
            do {
                let preferredDevice = microphoneManager.getPreferredDevice()
                let deviceUID = preferredDevice?.uniqueID
                logger.error("startRecording: device = \(deviceUID ?? "system default", privacy: .public), useSystemDefault = \(self.microphoneManager.useSystemDefault, privacy: .public)")
                microphoneManager.activeMicrophoneID = microphoneManager.useSystemDefault ? nil : deviceUID

                do {
                    try await audioCapture.start(deviceUID: deviceUID)
                } catch where deviceUID != nil {
                    // Fallback: se o device específico falhou, tenta system default
                    logger.error("startRecording: fallback para system default após erro: \(String(describing: error), privacy: .public)")
                    microphoneManager.activeMicrophoneID = nil
                    try await audioCapture.start(deviceUID: nil)
                }
                logger.error("startRecording: audioCapture.start() OK")
            } catch {
                logger.error("startRecording: ERRO final → \(String(describing: error), privacy: .public)")
                microphoneManager.activeMicrophoneID = nil
                state = .idle
                errorMessage = "Erro ao iniciar gravacao: \(error.localizedDescription)"
            }
        }
    }

    private func stopRecording() {
        state = .processing

        Task {
            do {
                // Aguarda engine iniciar completamente antes de parar
                await recordingTask?.value
                recordingTask = nil

                let samples = await audioCapture.stop()
                print("[zspeak] Amostras capturadas: \(samples.count) (\(Float(samples.count)/16000)s)")

                // Se nao ha audio suficiente, volta para idle
                guard samples.count > 8000 else { // Menos de 0.5s de audio
                    print("[zspeak] Áudio muito curto, descartando")
                    state = .idle
                    return
                }

                // Transcreve o audio
                let text = try await transcriber.transcribe(samples)
                print("[zspeak] Transcrição: '\(text)'")

                // Se o texto esta vazio (silencio), volta para idle
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    print("[zspeak] Texto vazio (silêncio), ignorando")
                    state = .idle
                    return
                }

                // Persiste no histórico
                lastTranscription = text
                store?.addRecord(
                    text: text,
                    modelName: "Parakeet TDT 0.6B V3",
                    duration: Double(samples.count) / 16000.0,
                    targetAppName: TextInserter.previousApp?.localizedName,
                    samples: samples
                )

                if accessibilityGranted {
                    // Insere o texto no app ativo
                    print("[zspeak] Inserindo texto no app ativo")
                    let inserted = textInserter.insert(text)
                    if !inserted {
                        textInserter.copyToClipboard(text)
                        errorMessage = "Falha ao inserir automaticamente. Texto copiado para o clipboard."
                    }
                } else {
                    textInserter.copyToClipboard(text)
                    errorMessage = "Transcrição copiada para o clipboard. Ative Acessibilidade para colar automaticamente."
                }

                state = .idle
            } catch {
                print("[zspeak] ERRO: \(error)")
                state = .idle
                errorMessage = "Erro na transcricao: \(error.localizedDescription)"
            }
        }
    }

    private func resolveMicrophonePermission() {
        switch microphoneManager.permissionState {
        case .authorized:
            startRecording()

        case .notDetermined:
            guard !isRequestingMicrophonePermission else { return }
            isRequestingMicrophonePermission = true
            errorMessage = "Solicitando acesso ao microfone..."

            Task {
                let granted = await microphoneManager.requestPermissionIfNeeded()
                isRequestingMicrophonePermission = false

                guard state == .idle else { return }

                if granted {
                    startRecording()
                } else {
                    updateMicrophonePermissionError()
                }
            }

        case .denied, .restricted, .unavailable:
            updateMicrophonePermissionError()
        }
    }

    private func updateMicrophonePermissionError() {
        switch microphoneManager.permissionState {
        case .unavailable:
            errorMessage = "O build atual não expõe NSMicrophoneUsageDescription. Rode zspeak como app bundle para liberar o microfone."
        case .denied, .restricted:
            errorMessage = "Microfone necessário para gravar. Ative em Ajustes do Sistema → Privacidade → Microfone."
        case .notDetermined:
            errorMessage = "Solicitando acesso ao microfone..."
        case .authorized:
            errorMessage = nil
        }
    }

}
