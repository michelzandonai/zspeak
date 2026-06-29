import AppKit
import Foundation
import os.log

private let logger = Logger(subsystem: "com.zspeak", category: "RecordingController")

/// Orquestra o ciclo de gravação: start → preparing → recording → processing → idle.
///
/// Responsabilidades:
/// - State machine (`RecordingState`)
/// - Priorização de microfone: itera candidatos → fallback pro system default
/// - Warm-up (cold path vs fast path)
/// - Transcrição da sessão (invoca `Transcribing`)
/// - Pós-processamento (vocabulário opcional + clipboard/insert)
/// - Persistência no histórico (callback fornecido pelo façade)
///
/// NÃO conhece:
/// - LLM / prompts de correção (em `LLMCoordinator`)
/// - Transcrição de arquivo / diarização (em `FileTranscriptionCoordinator`)
///
/// Exposto via @Observable para que a View leia `state`, `errorMessage`,
/// `lastTranscription` etc. diretamente quando quiser; o façade `AppState`
/// mantém propriedades espelhadas que delegam para aqui.
@MainActor
@Observable
final class RecordingController {

    // MARK: - Estado público

    enum RecordingState: Equatable {
        case idle          // Pronto para usar
        case preparing     // Hotkey acionado; engine subindo, aguardando 1º sample
        case recording     // Engine capturando áudio (1º sample já chegou)
        case processing    // Transcrevendo
    }

    var state: RecordingState = .idle
    var isModelReady: Bool = false
    var lastTranscription: String = ""
    var liveTranscriptionPreview: String = ""
    var lastTranscriptionRecordID: UUID?
    /// Exposto para leitura direta pelo façade — o setter é compartilhado via
    /// `reportError` (`AppState` observa e espelha no `errorMessage` público).
    var errorMessage: String? {
        didSet { onErrorMessageChange?(errorMessage) }
    }
    /// Setado externamente pelo `AppState` a partir do `AccessibilityManager`.
    var accessibilityGranted: Bool = false

    /// Callback do façade para sincronizar `AppState.errorMessage`. Permite que
    /// o façade mantenha uma única fonte de verdade compartilhada entre
    /// `RecordingController` e `LLMCoordinator`.
    var onErrorMessageChange: (@MainActor (String?) -> Void)?

    /// True enquanto o pipeline está ativo (cobre `.preparing` e `.recording`).
    var isRecordingOrPreparing: Bool {
        state == .preparing || state == .recording
    }

    // MARK: - Dependências injetadas

    let microphoneManager: MicrophoneManager
    private let audioCapture: any AudioCapturing
    private let transcriber: any Transcribing
    private let textInserter: any TextInserting

    /// Hooks sem acoplamento direto aos stores (injetados pelo `AppState`):
    /// - `applyVocabularyReplacements`: pós-transcrição, aplica substituições alias→term.
    /// - `shouldDeferInsertionAfterTranscription`: quando true, não cola/copia a
    ///   transcrição bruta; deixa o Modo Prompt inserir apenas o resultado da LLM.
    /// - `persistTranscription`: persiste o record no histórico e retorna o UUID gerado.
    var applyVocabularyReplacements: (@MainActor (String) -> String)?
    var shouldDeferInsertionAfterTranscription: (@MainActor () -> Bool)?
    var persistTranscription: (@MainActor (_ text: String, _ modelName: String, _ duration: Double, _ targetAppName: String?, _ samples: [Float]?) -> UUID?)?

    // MARK: - Tasks internas

    private var recordingTask: Task<Void, Never>?
    private var recordingSessionID: UUID?
    private var isRequestingMicrophonePermission = false
    private var liveTranscriptionSession: (any LiveTranscriptionSession)?
    private var liveTranscriptionSessionID: UUID?
    private var liveAudioPipe: LiveAudioChunkPipe?
    private var liveTranscriptionStartTask: Task<Void, Never>?
    private var liveAudioPumpTask: Task<Void, Never>?
    private var lastLiveText: String = ""

    private enum SettingsKey {
        static let playRecordingSounds = "playRecordingSounds"
    }

    /// Sons de feedback emitidos no início e fim da captura. Compensam o cold
    /// path: o usuário ouve o chime e sabe que pode falar — não precisa esperar
    /// nem olhar a UI. Pré-carregados no init para não adicionar latência no
    /// primeiro uso.
    private let startChime: NSSound? = NSSound(named: "Tink")
    private let stopChime: NSSound? = NSSound(named: "Pop")

    // MARK: - Init

    init(
        audioCapture: any AudioCapturing,
        transcriber: any Transcribing,
        textInserter: any TextInserting,
        microphoneManager: MicrophoneManager
    ) {
        self.audioCapture = audioCapture
        self.transcriber = transcriber
        self.textInserter = textInserter
        self.microphoneManager = microphoneManager
    }

    // MARK: - Inicialização do modelo ASR

    /// Carrega modelo ASR e deixa o engine em hot window antes de liberar a UI.
    func initialize() async {
        do {
            try await transcriber.initialize()
            await warmUpAudioCapture()
            isModelReady = true
        } catch {
            errorMessage = "Erro ao carregar modelos: \(error.localizedDescription)"
        }
    }

    /// Reprepara o engine após inicialização/stop mantendo o hot window ativo.
    func warmUpAudioCapture() async {
        guard microphoneManager.isPermissionGranted else { return }
        let preferredUID = microphoneManager.connectedMicrophones().first?.id
        do {
            try await audioCapture.warmUp(deviceUID: preferredUID)
        } catch {
            logger.info("warmUpAudioCapture: falhou (\(error.localizedDescription)) — start() usará cold path")
        }
    }

    func coolDownAudioCapture() async {
        await audioCapture.coolDown()
    }

    /// Leitura direta do nível de áudio (WaveformView).
    nonisolated func currentAudioLevel() async -> Float {
        audioCapture.currentAudioLevel()
    }

    /// Exposto para benchmarks e pipelines externos (ex: `AudioFileTranscriber`).
    func transcribe(_ samples: [Float]) async throws -> String {
        try await transcriber.transcribe(samples)
    }

    // MARK: - Toggle de gravação

    func toggleRecording() {
        logger.debug("toggleRecording: estado atual = \(String(describing: self.state))")
        switch state {
        case .idle:
            startRecording()
        case .preparing, .recording:
            stopRecording()
        case .processing:
            logger.debug("toggleRecording: ignorado durante processing")
        }
    }

    func startRecordingIfIdle() {
        guard state == .idle else { return }
        startRecording()
    }

    func stopRecordingIfActive() {
        guard isRecordingOrPreparing else { return }
        stopRecording()
    }

    /// Cancela gravação em andamento (ESC). Aceita `.preparing` e `.recording`.
    func cancelRecording() {
        guard isRecordingOrPreparing else { return }
        let taskToCancel = recordingTask
        let sessionID = recordingSessionID
        state = .idle
        recordingTask = nil
        taskToCancel?.cancel()
        Task {
            await taskToCancel?.value
            guard recordingSessionID == sessionID else { return }
            _ = await audioCapture.stop()
            await cancelLiveTranscription()
            recordingSessionID = nil
            // Repreparar engine para economizar cold start na próxima gravação.
            await warmUpAudioCapture()
        }
    }

    // MARK: - Fluxo interno

    private func startRecording() {
        guard isModelReady else {
            logger.error("startRecording: modelo não pronto")
            errorMessage = "Modelo ainda carregando, aguarde..."
            return
        }

        microphoneManager.refreshPermissionState()
        logger.debug("startRecording: permissão mic = \(self.microphoneManager.permissionState == .authorized ? "OK" : "NEGADA", privacy: .public)")
        guard microphoneManager.isPermissionGranted else {
            logger.error("startRecording: sem permissão de microfone, estado = \(String(describing: self.microphoneManager.permissionState))")
            resolveMicrophonePermission()
            return
        }

        state = .preparing
        errorMessage = nil
        TextInserter.saveFocusedApp()
        liveTranscriptionPreview = ""
        lastLiveText = ""
        let sessionID = UUID()
        recordingSessionID = sessionID
        let tStartRec = CFAbsoluteTimeGetCurrent()
        PerfSignposter.mark(.hotkey, metadata: ["state": "idle_to_preparing"])
        logger.info("t=0ms startRecording: estado → preparing")

        // Callback @Sendable que faz hop para MainActor e promove preparing → recording.
        // Também toca o chime "pronto pra falar" quando habilitado.
        let onFirstSample: @Sendable () -> Void = { [weak self] in
            // Marca pontual: callback chegou ao controller (t3). Mede o gap
            // entre o tap callback (`first_tap_callback`) e a primeira reação
            // observável pelo usuário (chime + estado .recording).
            PerfSignposter.mark(.firstSampleCallback)
            Task { @MainActor in
                guard let self else { return }
                guard self.state == .preparing else { return }
                guard self.recordingSessionID == sessionID else { return }
                self.state = .recording
                if self.playRecordingSounds {
                    self.startChime?.play()
                }
                let elapsed = (CFAbsoluteTimeGetCurrent() - tStartRec) * 1000
                logger.info("t=\(String(format: "%.0f", elapsed), privacy: .public)ms 1º sample → .recording + chime")
            }
        }

        // Fluxo otimizado: preferido + default. Se o preferido falhar, não
        // iteramos todos os candidatos (cada retry custa 100–300 ms de
        // engine.start()). Caímos direto para o default do sistema.
        recordingTask = Task {
            let onSamples = prepareLiveTranscriptionIfNeeded(sessionID: sessionID)
            let candidatos = microphoneManager.connectedMicrophones()
            let preferredUID = candidatos.first?.id

            // Tentativa 1: mic preferido (ou default se lista vazia)
            if let uid = preferredUID {
                microphoneManager.activeMicrophoneID = uid
                do {
                    try await audioCapture.start(
                        deviceUID: uid,
                        onFirstSample: onFirstSample,
                        onSamples: onSamples
                    )
                    let elapsed = (CFAbsoluteTimeGetCurrent() - tStartRec) * 1000
                    logger.info("t=\(String(format: "%.0f", elapsed), privacy: .public)ms audioCapture.start OK (preferred=\(uid, privacy: .public))")
                    return
                } catch {
                    logger.error("startRecording: preferido \(uid, privacy: .public) falhou (\(String(describing: error), privacy: .public)) — caindo para default")
                    if recordingSessionID == sessionID {
                        _ = await audioCapture.stop()
                    }
                }
                if Task.isCancelled { return }
            }

            // Tentativa 2 (última): default do sistema
            microphoneManager.activeMicrophoneID = nil
            do {
                try await audioCapture.start(
                    deviceUID: nil,
                    onFirstSample: onFirstSample,
                    onSamples: onSamples
                )
                let elapsed = (CFAbsoluteTimeGetCurrent() - tStartRec) * 1000
                logger.info("t=\(String(format: "%.0f", elapsed), privacy: .public)ms audioCapture.start OK (system default)")
            } catch {
                logger.error("startRecording: default falhou → \(String(describing: error), privacy: .public)")
                microphoneManager.activeMicrophoneID = nil
                await cancelLiveTranscription()
                guard recordingSessionID == sessionID else { return }
                state = .idle
                recordingSessionID = nil
                errorMessage = "Não foi possível iniciar gravação em nenhum microfone disponível"
            }
        }
    }

    private func stopRecording() {
        let taskToStop = recordingTask
        let sessionID = recordingSessionID
        state = .processing

        Task {
            do {
                await taskToStop?.value
                if recordingSessionID == sessionID {
                    recordingTask = nil
                }

                let samples = await audioCapture.stop()
                _ = await finishLiveTranscription()
                if recordingSessionID == sessionID {
                    recordingSessionID = nil
                }
                if playRecordingSounds {
                    stopChime?.play()
                }

                guard samples.count > 8000 else { // < 0.5s
                    state = .idle
                    clearLiveTranscriptionState()
                    await warmUpAudioCapture()
                    return
                }

                let trimResult = SpeechSampleTrimmer.trimForASR(samples)
                guard !trimResult.samples.isEmpty else {
                    state = .idle
                    clearLiveTranscriptionState()
                    await warmUpAudioCapture()
                    return
                }

                let rawText = try await PerfSignposter.measure(.asrTranscribe, metadata: [
                    "source": "microphone",
                    "samples_in": "\(samples.count)",
                    "samples_asr": "\(trimResult.samples.count)",
                    "trimmed_samples": "\(trimResult.removedSampleCount)",
                ]) {
                    try await transcriber.transcribe(trimResult.samples)
                }

                // Aplica vocabulário customizado (substituições alias → term) via hook
                let text = applyVocabularyReplacements?(rawText) ?? rawText

                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    state = .idle
                    clearLiveTranscriptionState()
                    await warmUpAudioCapture()
                    return
                }

                lastTranscription = text
                let newID = persistTranscription?(
                    text,
                    "Parakeet TDT 0.6B V3",
                    Double(samples.count) / 16000.0,
                    TextInserter.previousApp?.localizedName,
                    samples
                )
                lastTranscriptionRecordID = newID

                let shouldDeferInsertion = shouldDeferInsertionAfterTranscription?() ?? false
                if shouldDeferInsertion {
                    // Modo Prompt: não cola a transcrição bruta. Zera o contador
                    // para o LLM inserir direto o primeiro resultado, sem apagar
                    // um paste antigo por engano.
                    TextInserter.lastPastedCount = 0
                    logger.info("Modo Prompt ativo: transcrição bruta não será inserida antes da LLM")
                } else if accessibilityGranted {
                    let inserted = await textInserter.insert(text)
                    if !inserted {
                        textInserter.copyToClipboard(text)
                        errorMessage = "Falha ao inserir automaticamente. Texto copiado para o clipboard."
                    }
                } else {
                    textInserter.copyToClipboard(text)
                    errorMessage = "Transcrição copiada para o clipboard. Ative Acessibilidade para colar automaticamente."
                }

                state = .idle
                clearLiveTranscriptionState()
                await warmUpAudioCapture()
            } catch {
                state = .idle
                await cancelLiveTranscription()
                errorMessage = "Erro na transcricao: \(error.localizedDescription)"
                await warmUpAudioCapture()
            }
        }
    }

    private func prepareLiveTranscriptionIfNeeded(sessionID: UUID) -> (@Sendable ([Float]) -> Void)? {
        let pipe = LiveAudioChunkPipe()
        TextInserter.lastPastedCount = 0
        liveTranscriptionSessionID = sessionID
        liveAudioPipe = pipe

        liveTranscriptionStartTask = Task { [weak self, pipe, transcriber] in
            do {
                let liveSession = try await transcriber.startLiveTranscription { [weak self] update in
                    Task { @MainActor in
                        await self?.handleLiveTranscriptionUpdate(update, sessionID: sessionID)
                    }
                }
                let pumpTask = Task { [pipe, liveSession] in
                    for await samples in pipe.stream {
                        await liveSession.append(samples)
                    }
                }

                await MainActor.run {
                    guard let self, self.liveTranscriptionSessionID == sessionID else {
                        pumpTask.cancel()
                        Task { await liveSession.cancel() }
                        return
                    }
                    self.liveTranscriptionSession = liveSession
                    self.liveAudioPumpTask = pumpTask
                }
            } catch {
                logger.error("prepareLiveTranscriptionIfNeeded: streaming ASR indisponível (\(error.localizedDescription, privacy: .public))")
            }
        }

        return { [pipe] samples in
            pipe.yield(samples)
        }
    }

    private func handleLiveTranscriptionUpdate(_ update: LiveTranscriptionUpdate, sessionID: UUID) async {
        guard liveTranscriptionSessionID == sessionID else { return }
        guard state == .recording || state == .processing else { return }

        let text = applyVocabularyReplacements?(update.text) ?? update.text
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != lastLiveText else { return }

        lastLiveText = trimmed
        liveTranscriptionPreview = trimmed
    }

    private func finishLiveTranscription() async -> String? {
        liveAudioPipe?.finish()

        guard liveTranscriptionSession != nil || liveAudioPumpTask != nil else {
            liveTranscriptionStartTask?.cancel()
            liveTranscriptionStartTask = nil
            liveTranscriptionSessionID = nil
            liveAudioPipe = nil
            return nil
        }

        await liveTranscriptionStartTask?.value
        liveTranscriptionStartTask = nil
        await liveAudioPumpTask?.value
        liveAudioPumpTask = nil
        liveAudioPipe = nil

        guard let liveTranscriptionSession else { return nil }
        do {
            return try await liveTranscriptionSession.finish()
        } catch {
            logger.error("finishLiveTranscription: falhou (\(error.localizedDescription, privacy: .public))")
            return nil
        }
    }

    private func cancelLiveTranscription() async {
        liveAudioPipe?.finish()
        guard liveTranscriptionSession != nil || liveAudioPumpTask != nil else {
            liveTranscriptionStartTask?.cancel()
            clearLiveTranscriptionState()
            return
        }

        await liveTranscriptionStartTask?.value
        liveTranscriptionStartTask = nil
        await liveAudioPumpTask?.value
        await liveTranscriptionSession?.cancel()
        clearLiveTranscriptionState()
    }

    private func clearLiveTranscriptionState() {
        liveTranscriptionSession = nil
        liveTranscriptionSessionID = nil
        liveAudioPipe = nil
        liveTranscriptionStartTask = nil
        liveAudioPumpTask = nil
        liveTranscriptionPreview = ""
        lastLiveText = ""
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

    private var playRecordingSounds: Bool {
        UserDefaults.standard.bool(forKey: SettingsKey.playRecordingSounds)
    }
}
