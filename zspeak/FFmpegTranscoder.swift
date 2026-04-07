import Foundation
import os

/// Wrapper para chamar ffmpeg via Process e transcodar arquivos de áudio para WAV 16kHz mono
/// Usado pelo AudioFileTranscriber quando o formato não é suportado nativamente por AVAudioFile
/// (ex.: .opus/.ogg do WhatsApp, .wma, .amr, etc).
actor FFmpegTranscoder {

    static let shared = FFmpegTranscoder()

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.zspeak",
        category: "FFmpegTranscoder"
    )

    enum FFmpegError: LocalizedError {
        case binaryNotFound
        case transcodeFailed(String)
        case timeout
        case launchFailed(String)

        var errorDescription: String? {
            switch self {
            case .binaryNotFound:
                return "ffmpeg não encontrado no bundle do app. Rebuild via scripts/package_app.sh."
            case .transcodeFailed(let details):
                return "Falha ao transcodar áudio: \(details)"
            case .timeout:
                return "Transcodificação excedeu o tempo limite."
            case .launchFailed(let details):
                return "Não foi possível iniciar ffmpeg: \(details)"
            }
        }
    }

    /// Localiza o binário ffmpeg:
    /// 1. Embutido em Contents/MacOS/ffmpeg (produção)
    /// 2. Embutido em Contents/Resources/ffmpeg
    /// 3. Fallback dev: /opt/homebrew/bin/ffmpeg ou /usr/local/bin/ffmpeg
    nonisolated static var bundledFFmpegURL: URL? {
        let bundleURL = Bundle.main.bundleURL

        let macosPath = bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent("ffmpeg")
        if FileManager.default.isExecutableFile(atPath: macosPath.path) {
            return macosPath
        }

        let resourcesPath = bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("ffmpeg")
        if FileManager.default.isExecutableFile(atPath: resourcesPath.path) {
            return resourcesPath
        }

        // Fallback para dev runs via `swift run` (sem bundle estruturado)
        for devPath in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"] {
            if FileManager.default.isExecutableFile(atPath: devPath) {
                return URL(fileURLWithPath: devPath)
            }
        }

        return nil
    }

    /// Verifica rapidamente se o ffmpeg está disponível
    nonisolated static var isAvailable: Bool {
        bundledFFmpegURL != nil
    }

    /// Transcoda qualquer formato de áudio suportado pelo ffmpeg para WAV 16kHz mono PCM 16-bit LE.
    /// Retorna URL de arquivo temporário em NSTemporaryDirectory() — caller é responsável por removê-lo.
    /// - Parameters:
    ///   - inputURL: arquivo de entrada
    ///   - timeout: tempo máximo em segundos (default 300s / 5min)
    ///   - onProgress: callback chamado a cada update de progresso (0.0-1.0).
    ///                 Recebe `nil` quando a duração total é desconhecida (raro).
    /// - Returns: URL do WAV temporário gerado
    func transcodeToWAV(
        inputURL: URL,
        timeout: TimeInterval = 300,
        onProgress: (@Sendable (Double?) -> Void)? = nil
    ) async throws -> URL {
        guard let ffmpegURL = Self.bundledFFmpegURL else {
            throw FFmpegError.binaryNotFound
        }

        let outputURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("zspeak-\(UUID().uuidString).wav")

        let process = Process()
        process.executableURL = ffmpegURL
        process.arguments = [
            "-nostdin",                 // Não lê stdin (evita hangs)
            "-i", inputURL.path,
            "-ar", "16000",             // Sample rate 16 kHz
            "-ac", "1",                 // Mono
            "-c:a", "pcm_s16le",        // PCM 16-bit little-endian
            "-fflags", "+discardcorrupt", // Ignora frames corrompidos
            "-progress", "pipe:2",       // Emite progresso estruturado em stderr
            "-loglevel", "info",         // Precisa info para "Duration:" do header
            "-y",                        // Sobrescreve output se existir
            outputURL.path
        ]

        let stderrPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = stdoutPipe

        // Buffer com últimas linhas de stderr (para mensagem de erro se falhar)
        let stderrBuffer = StderrBuffer()

        // Handler de leitura assíncrona do stderr — parseia progresso e acumula linhas
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            guard let chunk = String(data: data, encoding: .utf8) else { return }

            stderrBuffer.append(chunk)

            if let onProgress {
                let (progress, durationDetected) = stderrBuffer.parseProgress()
                if progress != nil || durationDetected {
                    onProgress(progress)
                }
            }
        }

        do {
            try process.run()
        } catch {
            throw FFmpegError.launchFailed(error.localizedDescription)
        }

        // Aguarda o process com timeout usando TaskGroup
        let exitStatus = try await withThrowingTaskGroup(of: Int32.self) { group in
            group.addTask {
                await withCheckedContinuation { (cont: CheckedContinuation<Int32, Never>) in
                    process.terminationHandler = { proc in
                        cont.resume(returning: proc.terminationStatus)
                    }
                }
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if process.isRunning {
                    process.terminate()
                }
                throw FFmpegError.timeout
            }

            // Pega o primeiro que completar (sucesso do process) e cancela o timer
            guard let result = try await group.next() else {
                throw FFmpegError.transcodeFailed("Nenhum resultado do processo")
            }
            group.cancelAll()
            return result
        }

        // Limpa o handler antes de ler restante
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        guard exitStatus == 0 else {
            let errorText = stderrBuffer.lastNonProgressLines() ?? "exit code \(exitStatus)"
            try? FileManager.default.removeItem(at: outputURL)
            Self.logger.error("ffmpeg falhou (\(exitStatus)): \(errorText, privacy: .public)")
            throw FFmpegError.transcodeFailed(errorText)
        }

        // Valida que o arquivo foi gerado
        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            throw FFmpegError.transcodeFailed("Arquivo de saída não foi criado")
        }

        // Garante 100% no fim
        onProgress?(1.0)

        Self.logger.info("ffmpeg ok: \(inputURL.lastPathComponent, privacy: .public) → WAV")
        return outputURL
    }

    // MARK: - Parsers (funções puras testáveis)

    /// Extrai duração total em segundos de uma linha "Duration: HH:MM:SS.xx" do stderr do ffmpeg
    /// Retorna nil se não encontrado
    nonisolated static func parseDuration(_ text: String) -> Double? {
        // Procura pattern "Duration: HH:MM:SS.xx"
        guard let range = text.range(of: #"Duration:\s*(\d+):(\d+):(\d+\.?\d*)"#, options: .regularExpression) else {
            return nil
        }
        let match = String(text[range])
        let scanner = Scanner(string: match)
        _ = scanner.scanUpToCharacters(from: .decimalDigits)

        guard let hours = scanner.scanInt() else { return nil }
        _ = scanner.scanCharacter()
        guard let minutes = scanner.scanInt() else { return nil }
        _ = scanner.scanCharacter()
        guard let seconds = scanner.scanDouble() else { return nil }

        return Double(hours) * 3600 + Double(minutes) * 60 + seconds
    }

    /// Extrai out_time_us em microsegundos de uma linha "out_time_us=XXXXX" do progresso ffmpeg
    /// Retorna nil se não encontrado
    nonisolated static func parseOutTimeMicros(_ text: String) -> Int64? {
        guard let range = text.range(of: #"out_time_us=(\d+)"#, options: .regularExpression) else {
            return nil
        }
        let match = String(text[range])
        let scanner = Scanner(string: match)
        _ = scanner.scanUpToCharacters(from: .decimalDigits)
        return scanner.scanInt64()
    }
}

/// Buffer thread-safe que acumula linhas de stderr do ffmpeg e parseia progresso incremental
private final class StderrBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pendingText: String = ""
    private var allLines: [String] = []
    private var totalDurationSeconds: Double?

    func append(_ chunk: String) {
        lock.lock()
        defer { lock.unlock() }
        pendingText += chunk

        // Quebra em linhas completas (preserva incompletas em pendingText)
        while let newlineIdx = pendingText.firstIndex(of: "\n") {
            let line = String(pendingText[..<newlineIdx])
            allLines.append(line)
            pendingText = String(pendingText[pendingText.index(after: newlineIdx)...])
        }

        // Processa também o conteúdo separado por \r (ffmpeg progress usa \r às vezes)
        if !pendingText.isEmpty {
            let parts = pendingText.split(separator: "\r", omittingEmptySubsequences: false)
            if parts.count > 1 {
                for part in parts.dropLast() {
                    allLines.append(String(part))
                }
                pendingText = String(parts.last ?? "")
            }
        }
    }

    /// Parseia as últimas linhas para extrair progresso atual
    /// Retorna (progress, durationDetected). progress = nil se duration ainda desconhecida.
    /// durationDetected = true se a duração foi encontrada nesta chamada (notifica caller pra UI).
    func parseProgress() -> (progress: Double?, durationDetected: Bool) {
        lock.lock()
        defer { lock.unlock() }

        var detectedDuration = false

        // Procura Duration nas linhas se ainda não tem
        if totalDurationSeconds == nil {
            for line in allLines.reversed() {
                if let dur = FFmpegTranscoder.parseDuration(line) {
                    totalDurationSeconds = dur
                    detectedDuration = true
                    break
                }
            }
        }

        // Procura out_time_us mais recente
        var lastOutTimeMicros: Int64?
        for line in allLines.reversed() {
            if let micros = FFmpegTranscoder.parseOutTimeMicros(line) {
                lastOutTimeMicros = micros
                break
            }
        }

        guard let total = totalDurationSeconds, total > 0,
              let micros = lastOutTimeMicros else {
            return (nil, detectedDuration)
        }

        let currentSeconds = Double(micros) / 1_000_000.0
        let progress = min(1.0, max(0.0, currentSeconds / total))
        return (progress, detectedDuration)
    }

    /// Retorna últimas linhas que NÃO são de progresso (key=value) para usar em mensagem de erro
    func lastNonProgressLines() -> String? {
        lock.lock()
        defer { lock.unlock() }

        let nonProgress = allLines.filter { line in
            !line.contains("=") || line.contains("error") || line.contains("Error")
        }
        guard !nonProgress.isEmpty else { return nil }
        let last = nonProgress.suffix(5).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return last.isEmpty ? nil : last
    }
}

/// Remove arquivos temporários criados pelo transcoder
extension FFmpegTranscoder {
    nonisolated func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
