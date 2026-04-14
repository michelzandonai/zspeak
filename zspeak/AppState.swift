import SwiftUI
import AppKit
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

    /// Gerenciador de diarização de speakers — setado externamente pelo App.swift
    /// Usado pelo modo Reunião na transcrição de arquivos
    var diarizationManager: DiarizationManager?

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

    /// Transcreve um arquivo de áudio (qualquer formato suportado)
    /// - Suporta modo `.plain` (texto corrido) e `.meeting` (com identificação de interlocutores)
    /// - Salva automaticamente no histórico via TranscriptionStore.addRecord
    /// - Copia o texto final para o clipboard
    /// - Atualiza lastTranscription/lastTranscriptionRecordID para permitir "Aplicar prompt LLM" depois
    func transcribeFile(
        url: URL,
        mode: AudioFileTranscriber.Mode,
        numSpeakers: Int? = nil,
        onProgress: @escaping @MainActor (FileTranscriptionPhase) -> Void
    ) async throws -> FileTranscriptionResult {
        let fileTranscriber = AudioFileTranscriber(
            transcribe: { [weak self] samples in
                guard let self else { throw AudioFileTranscriber.TranscriberError.transcriptionFailed("AppState liberado") }
                return try await self.transcribe(samples)
            },
            diarizer: diarizationManager
        )

        let rawResult = try await fileTranscriber.transcribe(url: url, mode: mode, numSpeakers: numSpeakers, onProgress: onProgress)

        // Aplica vocabulário customizado (substituições alias → term) no texto final
        let correctedText = vocabularyStore?.applyReplacements(to: rawResult.text) ?? rawResult.text
        let result = FileTranscriptionResult(
            text: correctedText,
            segments: rawResult.segments,
            sourceFileName: rawResult.sourceFileName,
            durationSeconds: rawResult.durationSeconds,
            samples: rawResult.samples
        )

        // Persiste no histórico
        let modelName: String = {
            switch mode {
            case .plain: return "Parakeet TDT (arquivo)"
            case .meeting: return "Parakeet TDT + Diarizer"
            }
        }()

        let newID = store?.addRecord(
            text: result.text,
            modelName: modelName,
            duration: result.durationSeconds,
            targetAppName: nil,
            samples: result.samples
        )

        lastTranscription = result.text
        lastTranscriptionRecordID = newID

        // Copia para o clipboard
        textInserter.copyToClipboard(result.text)

        return result
    }

    /// Atualiza o map de nomes de speakers de um registro de transcrição (modo Reunião)
    func updateSpeakerNames(recordID: UUID, names: [String: String]) {
        store?.updateSpeakerNames(recordID: recordID, names: names)
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

    /// Usa o texto atual do clipboard como input do LLM e aplica o prompt selecionado.
    /// Permite ao usuário processar qualquer texto (não só transcrições) sem precisar gravar.
    /// TASK-012.
    func applyPromptFromClipboard() {
        guard let raw = NSPasteboard.general.string(forType: .string) else {
            errorMessage = "Clipboard vazio."
            return
        }
        applyPromptToTextInput(raw)
    }

    /// Aplica o prompt ativo num texto arbitrário fornecido pelo usuário.
    /// Usado pelo TextField do overlay quando o usuário cola/digita um texto e o paste é detectado.
    /// TASK-013.
    func applyPromptToTextInput(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            errorMessage = "Texto vazio."
            return
        }
        guard let prompt = correctionPromptStore?.activePrompt else {
            errorMessage = "Nenhum prompt ativo."
            return
        }
        // Define como input do LLM — texto colado não tem record de gravação associado
        lastTranscription = text
        lastTranscriptionRecordID = nil
        lastLLMResult = nil
        lastLLMPromptName = nil
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

                    // Salva no histórico linkado ao registro original.
                    // Mantém apenas o record persistido — NÃO sobrescreve lastTranscription
                    // nem lastTranscriptionRecordID (TASK-011): a fala original permanece
                    // visível no overlay e um próximo prompt processa o mesmo texto base.
                    _ = store?.addRecord(
                        text: trimmed,
                        modelName: "LLM: \(prompt.name)",
                        duration: 0,
                        targetAppName: TextInserter.previousApp?.localizedName,
                        samples: nil,
                        sourceRecordID: originalID
                    )

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

            // Pré-aquece o audio engine com o device prioritário para encurtar
            // a latência do primeiro start() após o hotkey (de ~380ms para ~170ms).
            // prepare() não abre o HAL → não acende o indicador de microfone.
            await warmUpAudioCapture()
        } catch {
            errorMessage = "Erro ao carregar modelos: \(error.localizedDescription)"
        }
    }

    /// Pré-aquece o `AudioCapture` com o device prioritário atual.
    /// Chamado no startup e sempre que a lista/ordem de mics muda.
    /// Silencia erros: se o warmUp falhar, o próximo `start()` cai no cold
    /// path normal — mesmo comportamento pré-fix.
    func warmUpAudioCapture() async {
        guard microphoneManager.isPermissionGranted else { return }

        // Mesma lógica de startRecording: primeiro da lista priorizada, ou nil
        // (system default) se o toggle "Usar padrão do sistema" está ligado.
        let preferredUID = microphoneManager.connectedMicrophones().first?.id
        do {
            try await audioCapture.warmUp(deviceUID: preferredUID)
        } catch {
            logger.info("warmUpAudioCapture: falhou (\(error.localizedDescription)) — start() usará cold path")
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
            await warmUpAudioCapture()
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
            // Lista ordenada de candidatos. Vazia → usa apenas system default.
            let candidatos = microphoneManager.connectedMicrophones()

            if candidatos.isEmpty {
                logger.info("startRecording: candidatos vazios, usando system default")
                microphoneManager.activeMicrophoneID = nil
                do {
                    try await audioCapture.start(deviceUID: nil)
                    logger.info("startRecording: mic ativo = system default")
                } catch {
                    logger.error("startRecording: system default falhou → \(String(describing: error), privacy: .public)")
                    microphoneManager.activeMicrophoneID = nil
                    state = .idle
                    errorMessage = "Não foi possível iniciar gravação em nenhum microfone disponível"
                }
                return
            }

            let nomes = candidatos.map(\.name).joined(separator: ", ")
            logger.info("startRecording: candidatos = [\(nomes, privacy: .public)]")

            // Tenta cada candidato em ordem. Primeiro sucesso encerra.
            var sucesso = false
            for (idx, mic) in candidatos.enumerated() {
                logger.info("startRecording: tentando mic \(mic.name, privacy: .public) (pos \(idx + 1)/\(candidatos.count))")
                microphoneManager.activeMicrophoneID = mic.id
                do {
                    try await audioCapture.start(deviceUID: mic.id)
                    logger.info("startRecording: mic \(mic.name, privacy: .public) OK")
                    logger.info("startRecording: mic ativo = \(mic.name, privacy: .public) (\(mic.id, privacy: .public))")
                    sucesso = true
                    break
                } catch {
                    logger.error("startRecording: mic \(mic.name, privacy: .public) (\(mic.id, privacy: .public)) falhou (\(String(describing: error), privacy: .public)), tentando próximo")
                    // Limpeza preventiva: engine pode ter ficado semi-iniciado
                    _ = await audioCapture.stop()
                }
            }

            // Se nenhum da lista funcionou, tenta system default como último recurso
            if !sucesso {
                logger.info("startRecording: caindo para system default")
                microphoneManager.activeMicrophoneID = nil
                do {
                    try await audioCapture.start(deviceUID: nil)
                    logger.info("startRecording: mic ativo = system default")
                } catch {
                    logger.error("startRecording: system default falhou → \(String(describing: error), privacy: .public)")
                    microphoneManager.activeMicrophoneID = nil
                    state = .idle
                    errorMessage = "Não foi possível iniciar gravação em nenhum microfone disponível"
                }
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
                let rawText = try await transcriber.transcribe(samples)

                // Aplica vocabulário customizado (substituições alias → term)
                let text = vocabularyStore?.applyReplacements(to: rawText) ?? rawText

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

                // Re-aquece para a próxima gravação ficar no fast path
                await warmUpAudioCapture()
            } catch {
                state = .idle
                errorMessage = "Erro na transcricao: \(error.localizedDescription)"
                await warmUpAudioCapture()
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
