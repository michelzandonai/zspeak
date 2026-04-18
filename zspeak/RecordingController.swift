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
    /// - `persistTranscription`: persiste o record no histórico e retorna o UUID gerado.
    var applyVocabularyReplacements: (@MainActor (String) -> String)?
    var persistTranscription: (@MainActor (_ text: String, _ modelName: String, _ duration: Double, _ targetAppName: String?, _ samples: [Float]?) -> UUID?)?

    // MARK: - Tasks internas

    private var recordingTask: Task<Void, Never>?
    private var isRequestingMicrophonePermission = false

    /// Duração padrão do hot window (engine aberto + pre-roll ativo) após um
    /// sinal de uso. Após esse tempo sem nova atividade, `coolDown` desliga o
    /// engine e o indicador do mic apaga. Reinicia a cada gravação.
    private static let hotWindowDuration: TimeInterval = 300  // 5 min

    /// Task em dormida que dispara o coolDown quando a hot window expira.
    /// Cancelada e recriada a cada `warmUpAudioCapture()` bem-sucedido.
    private var hotWindowExpireTask: Task<Void, Never>?

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

    /// Carrega modelo ASR e pré-aquece o engine. Chamado no startup.
    func initialize() async {
        do {
            try await transcriber.initialize()
            isModelReady = true
            await warmUpAudioCapture()
        } catch {
            errorMessage = "Erro ao carregar modelos: \(error.localizedDescription)"
        }
    }

    /// Abre o hot window do engine com o device prioritário: HAL ativo, pre-roll
    /// alimentado continuamente. Silencia erros — se falhar, o próximo `start()`
    /// cai no cold path normal.
    ///
    /// Também agenda a expiração da janela. Após `hotWindowDuration` segundos
    /// de inatividade, o engine é desligado e o indicador do mic apaga.
    func warmUpAudioCapture() async {
        guard microphoneManager.isPermissionGranted else { return }
        let preferredUID = microphoneManager.connectedMicrophones().first?.id
        do {
            try await audioCapture.warmUp(deviceUID: preferredUID)
            scheduleHotWindowExpiration()
        } catch {
            logger.info("warmUpAudioCapture: falhou (\(error.localizedDescription)) — start() usará cold path")
        }
    }

    /// (Re)agenda a expiração do hot window. Cancela qualquer expiração
    /// pendente e recria a dormida. Se o app estiver em gravação ativa no
    /// momento do disparo, o coolDown é pulado — a próxima `warmUpAudioCapture`
    /// pós-stop vai reagendar normalmente.
    private func scheduleHotWindowExpiration() {
        hotWindowExpireTask?.cancel()
        hotWindowExpireTask = Task { [weak self] in
            let nanos = UInt64(Self.hotWindowDuration * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled, let self else { return }
            // Só desliga se o recorder está ocioso — não interrompe gravação.
            guard self.state == .idle else { return }
            await self.audioCapture.coolDown()
            logger.info("hotWindow: expirou após \(Int(Self.hotWindowDuration))s de inatividade — coolDown")
        }
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
        state = .idle
        recordingTask?.cancel()
        Task {
            await recordingTask?.value
            recordingTask = nil
            _ = await audioCapture.stop()
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
        logger.debug("startRecording: estado → preparing")

        // Callback @Sendable que faz hop para MainActor e promove preparing → recording.
        let onFirstSample: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                guard self.state == .preparing else { return }
                self.state = .recording
                logger.debug("startRecording: 1º sample chegou → estado → recording")
            }
        }

        recordingTask = Task {
            let candidatos = microphoneManager.connectedMicrophones()

            if candidatos.isEmpty {
                logger.debug("startRecording: candidatos vazios, usando system default")
                microphoneManager.activeMicrophoneID = nil
                do {
                    try await audioCapture.start(deviceUID: nil, onFirstSample: onFirstSample)
                    logger.debug("startRecording: mic ativo = system default")
                } catch {
                    logger.error("startRecording: system default falhou → \(String(describing: error), privacy: .public)")
                    microphoneManager.activeMicrophoneID = nil
                    state = .idle
                    errorMessage = "Não foi possível iniciar gravação em nenhum microfone disponível"
                }
                return
            }

            let nomes = candidatos.map(\.name).joined(separator: ", ")
            logger.debug("startRecording: candidatos = [\(nomes, privacy: .public)]")

            var sucesso = false
            for (idx, mic) in candidatos.enumerated() {
                if Task.isCancelled { return }
                logger.debug("startRecording: tentando mic \(mic.name, privacy: .public) (pos \(idx + 1)/\(candidatos.count))")
                microphoneManager.activeMicrophoneID = mic.id
                do {
                    try await audioCapture.start(deviceUID: mic.id, onFirstSample: onFirstSample)
                    logger.debug("startRecording: mic \(mic.name, privacy: .public) OK; mic ativo = \(mic.id, privacy: .public)")
                    sucesso = true
                    break
                } catch {
                    logger.error("startRecording: mic \(mic.name, privacy: .public) (\(mic.id, privacy: .public)) falhou (\(String(describing: error), privacy: .public)), tentando próximo")
                    _ = await audioCapture.stop()
                }
            }

            if !sucesso {
                if Task.isCancelled { return }
                logger.debug("startRecording: caindo para system default")
                microphoneManager.activeMicrophoneID = nil
                do {
                    try await audioCapture.start(deviceUID: nil, onFirstSample: onFirstSample)
                    logger.debug("startRecording: mic ativo = system default")
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
                await recordingTask?.value
                recordingTask = nil

                let samples = await audioCapture.stop()

                guard samples.count > 8000 else { // < 0.5s
                    state = .idle
                    return
                }

                let rawText = try await transcriber.transcribe(samples)

                // Aplica vocabulário customizado (substituições alias → term) via hook
                let text = applyVocabularyReplacements?(rawText) ?? rawText

                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    state = .idle
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
