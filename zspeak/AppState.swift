import SwiftUI
import FluidAudio
import os.log

private let logger = Logger(subsystem: "com.zspeak", category: "AppState")

/// Estado global da aplicacao — controla o fluxo de gravacao e transcricao
@MainActor
@Observable
final class AppState {

    // MARK: - Estado

    enum RecordingState: Equatable {
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

    /// Store de prompts de correção LLM — setado externamente pelo App.swift
    var correctionPromptStore: CorrectionPromptStore?

    /// Gerenciador do Modo Prompt LLM (overlay persistente) — setado externamente pelo App.swift
    var promptModeManager: PromptModeManager?

    /// ID do último registro de transcrição salvo — usado para linkar correções LLM
    var lastTranscriptionRecordID: UUID?

    /// Último resultado gerado pela correção LLM (para exibir no overlay)
    var lastLLMResult: String?

    /// Nome do prompt usado na última correção LLM
    var lastLLMPromptName: String?

    /// Toggle global de correção LLM — persiste em UserDefaults
    var llmCorrectionEnabled: Bool = UserDefaults.standard.bool(forKey: "llmCorrectionEnabled") {
        didSet { UserDefaults.standard.set(llmCorrectionEnabled, forKey: "llmCorrectionEnabled") }
    }

    // MARK: - Dependencias

    let microphoneManager: MicrophoneManager
    private let audioCapture = AudioCapture()
    private let transcriber = Transcriber()
    private let textInserter = TextInserter()
    private let llmManager = LLMCorrectionManager()

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

    /// Aplica o prompt ativo na última transcrição e substitui o texto colado
    var isApplyingPrompt = false

    /// Aplica o prompt ativo (configurado em CorrectionPromptStore) na última transcrição
    func applyPrompt() {
        guard let prompt = correctionPromptStore?.activePrompt else {
            errorMessage = "Nenhum prompt ativo."
            return
        }
        applyPromptToLast(prompt)
    }

    /// Aplica um prompt específico na última transcrição, substituindo o texto colado.
    /// Salva o resultado no histórico linkado ao registro original via sourceRecordID.
    func applyPromptToLast(_ prompt: CorrectionPrompt) {
        guard !lastTranscription.isEmpty else {
            errorMessage = "Nenhuma transcrição para processar."
            return
        }
        guard !isApplyingPrompt else { return }

        // Re-salva o app em foco atual (pode ter mudado desde a transcrição)
        TextInserter.saveFocusedApp()

        isApplyingPrompt = true
        errorMessage = nil
        // Limpa resultado anterior e seta nome do prompt para UI mostrar streaming
        lastLLMResult = ""
        lastLLMPromptName = prompt.name
        let originalID = lastTranscriptionRecordID
        let originalText = lastTranscription

        Task {
            do {
                let corrected = try await llmManager.correct(
                    text: originalText,
                    systemPrompt: prompt.systemPrompt,
                    onPartial: { [weak self] partial in
                        Task { @MainActor in
                            self?.lastLLMResult = partial
                        }
                    }
                )
                let trimmed = corrected.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    // Substituir texto já colado no app via Cmd+Z + novo Cmd+V
                    if accessibilityGranted {
                        _ = textInserter.replaceLastPaste(trimmed)
                    } else {
                        textInserter.copyToClipboard(trimmed)
                    }

                    // Salva no histórico linkado ao registro original
                    let newID = store?.addRecord(
                        text: trimmed,
                        modelName: "LLM: \(prompt.name)",
                        duration: 0,
                        targetAppName: TextInserter.previousApp?.localizedName,
                        samples: nil,
                        sourceRecordID: originalID
                    )

                    lastTranscription = trimmed
                    lastTranscriptionRecordID = newID
                    lastLLMResult = trimmed
                    lastLLMPromptName = prompt.name
                    logger.info("Prompt '\(prompt.name)' aplicado: \(trimmed.count) chars")
                } else {
                    errorMessage = "LLM retornou vazio."
                }
            } catch {
                errorMessage = "Erro ao aplicar prompt: \(error.localizedDescription)"
                logger.error("applyPromptToLast falhou: \(error.localizedDescription)")
            }
            isApplyingPrompt = false
        }
    }

    /// Baixa o modelo LLM para correção — retorna estado final
    func downloadLLMModel() async -> LLMCorrectionManager.ModelState {
        do {
            try await llmManager.downloadModel()
        } catch {
            logger.error("Erro no download do modelo LLM: \(error.localizedDescription)")
        }
        return await llmManager.modelState
    }

    /// Estado atual do modelo LLM
    func llmModelState() async -> LLMCorrectionManager.ModelState {
        await llmManager.modelState
    }

    /// Carrega modelo LLM na memória (sem download)
    func loadLLMModel() async -> LLMCorrectionManager.ModelState {
        do {
            try await llmManager.loadModel()
        } catch {
            logger.error("Erro ao carregar modelo LLM: \(error.localizedDescription)")
        }
        return await llmManager.modelState
    }

    /// Pré-carrega o modelo LLM em background (não-bloqueante) e ativa keep-alive.
    /// Chamado quando o Modo Prompt é ligado para eliminar cold start.
    func preloadLLMAndKeepAlive() {
        Task.detached(priority: .userInitiated) { [llmManager] in
            await llmManager.setKeepAlive(true)
            let state = await llmManager.modelState
            if case .downloaded = state {
                try? await llmManager.loadModel()
            }
        }
    }

    /// Libera keep-alive do LLM — chamado quando o Modo Prompt é desligado.
    /// O idle timer volta a rodar normalmente e descarrega após 120s.
    func releaseLLMKeepAlive() {
        Task.detached(priority: .utility) { [llmManager] in
            await llmManager.setKeepAlive(false)
        }
    }

    /// Remove modelo LLM do disco
    func removeLLMModel() async {
        do {
            try await llmManager.deleteModel()
        } catch {
            logger.error("Erro ao remover modelo LLM: \(error.localizedDescription)")
        }
    }

    /// Tamanho do modelo LLM no disco
    func llmModelSizeOnDisk() async -> Int64? {
        await llmManager.modelSizeOnDisk()
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

    /// Carrega modelo ASR — chamado no startup do app
    func initialize() async {
        do {
            try await transcriber.initialize()
            isModelReady = true

            // Aplica vocabulário customizado se configurado
            do {
                try await applyVocabulary()
            } catch {
                logger.error("Falha ao aplicar vocabulário: \(error.localizedDescription)")
            }
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

                // Se nao ha audio suficiente, volta para idle
                guard samples.count > 8000 else { // Menos de 0.5s de audio
                    state = .idle
                    return
                }

                // Transcreve o audio
                let text = try await transcriber.transcribe(samples)

                // Se o texto esta vazio (silencio), volta para idle
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    state = .idle
                    return
                }

                // Persiste no histórico
                lastTranscription = text
                let newID = store?.addRecord(
                    text: text,
                    modelName: "Parakeet TDT 0.6B V3",
                    duration: Double(samples.count) / 16000.0,
                    targetAppName: TextInserter.previousApp?.localizedName,
                    samples: samples
                )
                lastTranscriptionRecordID = newID

                if accessibilityGranted {
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
