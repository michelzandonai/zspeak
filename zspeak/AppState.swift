import SwiftUI
import FluidAudio

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

    // MARK: - Dependencias

    private let audioCapture = AudioCapture()
    private let vadManager = VADManagerWrapper()
    private let transcriber = Transcriber()
    private let textInserter = TextInserter()

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
        } catch {
            errorMessage = "Erro ao carregar modelos: \(error.localizedDescription)"
        }
    }

    // MARK: - Toggle de gravacao

    /// Alterna entre gravar e parar — chamado pela hotkey
    func toggleRecording() {
        switch state {
        case .idle:
            startRecording()
        case .recording:
            stopRecording()
        case .processing:
            break // Ignora durante processamento
        }
    }

    // MARK: - Gravacao

    private func startRecording() {
        guard isModelReady else { return }
        state = .recording
        errorMessage = nil

        Task {
            do {
                try await audioCapture.start()
            } catch {
                state = .idle
                errorMessage = "Erro ao iniciar gravacao: \(error.localizedDescription)"
            }
        }
    }

    private func stopRecording() {
        state = .processing

        Task {
            do {
                // Para a captura e obtem as amostras de audio
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

                // Insere o texto no app ativo
                lastTranscription = text
                textInserter.insert(text)

                state = .idle
            } catch {
                state = .idle
                errorMessage = "Erro na transcricao: \(error.localizedDescription)"
            }
        }
    }
}
