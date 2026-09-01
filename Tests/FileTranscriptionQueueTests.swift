import Foundation
import Testing
@testable import zspeak

@Suite("FileTranscriptionQueue")
@MainActor
struct FileTranscriptionQueueTests {

    // MARK: - Helpers

    private func makeTmpDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    /// Cria um arquivo com extensão suportada. O conteúdo não importa: o
    /// handler de transcrição é falso nestes testes.
    private func makeFile(named name: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data([0x00, 0x01, 0x02]).write(to: url)
        return url
    }

    private func makeResult(text: String, fileName: String, samples: [Float] = []) -> FileTranscriptionResult {
        FileTranscriptionResult(
            text: text,
            segments: nil,
            sourceFileName: fileName,
            durationSeconds: 1.5,
            samples: samples
        )
    }

    /// Instala um handler que devolve "texto de <arquivo>" e registra a ordem.
    private func installEchoHandler(
        on queue: FileTranscriptionQueue,
        recorder: OrderRecorder
    ) {
        queue.transcribeHandler = { [weak recorder] request, onProgress in
            recorder?.append(request.url.lastPathComponent)
            onProgress(.transcribing(current: 1, total: 1))
            return FileTranscriptionQueue.Outcome(
                result: FileTranscriptionResult(
                    text: "texto de \(request.url.lastPathComponent)",
                    segments: nil,
                    sourceFileName: request.url.lastPathComponent,
                    durationSeconds: 1.5,
                    samples: [0.1, 0.2]
                ),
                recordID: UUID()
            )
        }
    }

    @MainActor
    final class OrderRecorder {
        var values: [String] = []
        func append(_ value: String) { values.append(value) }
    }

    private func waitUntilIdle(_ queue: FileTranscriptionQueue, timeout: TimeInterval = 15) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while queue.isRunning || queue.items.contains(where: { !$0.status.isFinished }) {
            if Date() > deadline { Issue.record("Fila não terminou em \(timeout)s"); return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: - Enfileiramento

    @Test("Arquivo com extensão não suportada entra como falha visível")
    func unsupportedFileBecomesFailedItem() throws {
        let dir = try makeTmpDir()
        let queue = FileTranscriptionQueue()

        let txt = try makeFile(named: "notas.txt", in: dir)
        let ids = queue.enqueue(urls: [txt], mode: .plain)

        #expect(ids.count == 1)
        #expect(queue.items.count == 1)
        #expect(queue.failedCount == 1)
        #expect(queue.items[0].errorMessage?.contains("não é suportado") == true)
        // Nada aceito: a fila não deve nem tentar rodar.
        #expect(queue.isRunning == false)
    }

    @Test("Lote roda em série, na ordem, e conclui todos os itens")
    func processesBatchInOrder() async throws {
        let dir = try makeTmpDir()
        let queue = FileTranscriptionQueue()
        let recorder = OrderRecorder()
        installEchoHandler(on: queue, recorder: recorder)

        let urls = try (1...3).map { try makeFile(named: "\($0).wav", in: dir) }
        queue.enqueue(urls: urls, mode: .plain)

        try await waitUntilIdle(queue)

        #expect(recorder.values == ["1.wav", "2.wav", "3.wav"])
        #expect(queue.doneCount == 3)
        #expect(queue.failedCount == 0)
    }

    @Test("Texto consolidado traz o nome de cada arquivo e ignora não concluídos")
    func combinedTextIncludesFileNames() async throws {
        let dir = try makeTmpDir()
        let queue = FileTranscriptionQueue()
        installEchoHandler(on: queue, recorder: OrderRecorder())

        let ok = try makeFile(named: "audio1.wav", in: dir)
        let bad = try makeFile(named: "planilha.csv", in: dir)
        queue.enqueue(urls: [ok, bad], mode: .plain)

        try await waitUntilIdle(queue)

        let combined = queue.combinedText
        #expect(combined.contains("— audio1.wav —"))
        #expect(combined.contains("texto de audio1.wav"))
        #expect(combined.contains("planilha.csv") == false)
    }

    @Test("Falha do handler vira item .failed com a mensagem do erro")
    func handlerErrorMarksItemFailed() async throws {
        let dir = try makeTmpDir()
        let queue = FileTranscriptionQueue()
        queue.transcribeHandler = { _, _ in
            throw AudioFileTranscriber.TranscriberError.emptyAudio
        }

        let url = try makeFile(named: "curto.wav", in: dir)
        queue.enqueue(urls: [url], mode: .plain)
        try await waitUntilIdle(queue)

        #expect(queue.failedCount == 1)
        #expect(queue.items[0].errorMessage?.contains("vazio") == true)
    }

    @Test("onQueueFinished reporta os IDs concluídos e a contagem de falhas")
    func reportsFinishedCounts() async throws {
        let dir = try makeTmpDir()
        let queue = FileTranscriptionQueue()
        let recorder = OrderRecorder()
        queue.transcribeHandler = { request, _ in
            if request.url.lastPathComponent == "ruim.wav" {
                throw AudioFileTranscriber.TranscriberError.emptyAudio
            }
            return FileTranscriptionQueue.Outcome(
                result: FileTranscriptionResult(
                    text: "ok",
                    segments: nil,
                    sourceFileName: request.url.lastPathComponent,
                    durationSeconds: 1,
                    samples: []
                ),
                recordID: nil
            )
        }
        let finishedBox = FinishedBox()
        queue.onQueueFinished = { succeededIDs, failed in
            finishedBox.record(ids: succeededIDs, failed: failed)
            recorder.append("finished")
        }

        let good = try makeFile(named: "bom.wav", in: dir)
        let bad = try makeFile(named: "ruim.wav", in: dir)
        queue.enqueue(urls: [good, bad], mode: .plain)
        try await waitUntilIdle(queue)

        #expect(recorder.values == ["finished"])
        #expect(finishedBox.failed == 1)
        #expect(finishedBox.ids.count == 1)
        #expect(queue.item(id: finishedBox.ids[0])?.fileName == "bom.wav")
    }

    @Test("Clipboard do lote só considera o que terminou nesta rodada")
    func combinedTextIsScopedToRun() async throws {
        let dir = try makeTmpDir()
        let queue = FileTranscriptionQueue()
        installEchoHandler(on: queue, recorder: OrderRecorder())

        // Primeira rodada, deixada na lista.
        let antigo = try makeFile(named: "antigo.wav", in: dir)
        queue.enqueue(urls: [antigo], mode: .plain)
        try await waitUntilIdle(queue)

        // Segunda rodada: o consolidado desta rodada não pode trazer o antigo.
        let novo = try makeFile(named: "novo.wav", in: dir)
        let ids = queue.enqueue(urls: [novo], mode: .plain)
        try await waitUntilIdle(queue)

        let daRodada = queue.combinedText(for: ids)
        #expect(daRodada.contains("novo.wav"))
        #expect(daRodada.contains("antigo.wav") == false)

        // Já o botão "Copiar tudo" continua entregando a lista inteira.
        #expect(queue.combinedText.contains("antigo.wav"))
        #expect(queue.combinedText.contains("novo.wav"))
    }

    @MainActor
    final class FinishedBox {
        var ids: [UUID] = []
        var failed = 0
        func record(ids: [UUID], failed: Int) {
            self.ids = ids
            self.failed = failed
        }
    }

    @Test("prepareForMode roda antes do item de reunião")
    func callsPrepareForMode() async throws {
        let dir = try makeTmpDir()
        let queue = FileTranscriptionQueue()
        let recorder = OrderRecorder()
        queue.prepareForMode = { mode in
            recorder.append("prepare:\(mode.rawValue)")
        }
        queue.transcribeHandler = { request, _ in
            recorder.append("transcribe")
            return FileTranscriptionQueue.Outcome(
                result: FileTranscriptionResult(
                    text: "ok",
                    segments: nil,
                    sourceFileName: request.url.lastPathComponent,
                    durationSeconds: 1,
                    samples: []
                ),
                recordID: nil
            )
        }

        let url = try makeFile(named: "reuniao.wav", in: dir)
        queue.enqueue(urls: [url], mode: .meeting)
        try await waitUntilIdle(queue)

        #expect(recorder.values == ["prepare:meeting", "transcribe"])
    }

    // MARK: - Cancelamento e limpeza

    @Test("cancelAll marca os pendentes como cancelados")
    func cancelAllMarksPending() async throws {
        let dir = try makeTmpDir()
        let queue = FileTranscriptionQueue()
        // Handler que trava até ser cancelado: mantém a fila ocupada no item 1.
        queue.transcribeHandler = { _, _ in
            try await Task.sleep(nanoseconds: 5_000_000_000)
            throw CancellationError()
        }

        let urls = try (1...3).map { try makeFile(named: "\($0).wav", in: dir) }
        queue.enqueue(urls: urls, mode: .plain)

        // Espera o primeiro item sair de .pending
        let deadline = Date().addingTimeInterval(15)
        while queue.items[0].status.isPending {
            if Date() > deadline { Issue.record("Item 1 não começou"); return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        queue.cancelAll()
        try await waitUntilIdle(queue)

        #expect(queue.doneCount == 0)
        #expect(queue.items.allSatisfy { $0.status == .cancelled })
    }

    @Test("clearFinished remove só os itens já finalizados")
    func clearFinishedKeepsPending() async throws {
        let dir = try makeTmpDir()
        let queue = FileTranscriptionQueue()
        installEchoHandler(on: queue, recorder: OrderRecorder())

        let urls = try (1...2).map { try makeFile(named: "\($0).wav", in: dir) }
        queue.enqueue(urls: urls, mode: .plain)
        try await waitUntilIdle(queue)

        #expect(queue.items.count == 2)
        queue.clearFinished()
        #expect(queue.items.isEmpty)
    }

    @Test("Transcrever de novo tira o item antigo, sem texto repetido no Copiar tudo")
    func removeDropsFinishedItem() async throws {
        let dir = try makeTmpDir()
        let queue = FileTranscriptionQueue()
        installEchoHandler(on: queue, recorder: OrderRecorder())

        let url = try makeFile(named: "audio.wav", in: dir)
        let first = try #require(queue.enqueue(urls: [url], mode: .plain).first)
        try await waitUntilIdle(queue)

        // Segunda rodada do MESMO arquivo, como no botão "Transcrever de novo".
        queue.remove(itemID: first)
        _ = queue.enqueue(urls: [url], mode: .plain)
        try await waitUntilIdle(queue)

        #expect(queue.items.count == 1)
        #expect(queue.item(id: first) == nil)
        // Uma ocorrência só: o item antigo não sobrou para duplicar o texto.
        #expect(queue.combinedText.components(separatedBy: "texto de audio.wav").count == 2)
        // O arquivo do usuário continua em disco.
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("Item em execução não é removido pelo remove")
    func removeIgnoresRunningItem() async throws {
        let dir = try makeTmpDir()
        let queue = FileTranscriptionQueue()

        // Handler lento o bastante para dar tempo de tentar remover no meio.
        queue.transcribeHandler = { [self] request, _ in
            try await Task.sleep(nanoseconds: 400_000_000)
            return FileTranscriptionQueue.Outcome(
                result: makeResult(text: "ok", fileName: request.url.lastPathComponent),
                recordID: nil
            )
        }

        let url = try makeFile(named: "lento.wav", in: dir)
        let id = try #require(queue.enqueue(urls: [url], mode: .plain).first)

        let deadline = Date().addingTimeInterval(5)
        while queue.item(id: id)?.status != .running {
            if Date() > deadline { Issue.record("Item não entrou em execução"); return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        queue.remove(itemID: id)
        #expect(queue.items.count == 1)
        #expect(queue.item(id: id)?.status == .running)

        try await waitUntilIdle(queue)
        #expect(queue.item(id: id)?.status == .done)
    }

    @Test("Arquivo temporário de ingestão é apagado ao sair da fila")
    func removesOwnedSourceFile() async throws {
        let dir = try makeTmpDir()
        let queue = FileTranscriptionQueue()
        installEchoHandler(on: queue, recorder: OrderRecorder())

        let url = try makeFile(named: "recebido.wav", in: dir)
        queue.enqueue(urls: [url], mode: .plain, ownsSourceFiles: true)
        try await waitUntilIdle(queue)

        // Ainda existe enquanto o item está na lista (permite reprocessar).
        #expect(FileManager.default.fileExists(atPath: url.path))

        queue.clearFinished()
        #expect(FileManager.default.fileExists(atPath: url.path) == false)
    }

    @Test("Arquivo de origem que não é da fila nunca é apagado")
    func keepsUserOwnedSourceFile() async throws {
        let dir = try makeTmpDir()
        let queue = FileTranscriptionQueue()
        installEchoHandler(on: queue, recorder: OrderRecorder())

        let url = try makeFile(named: "meu-audio.wav", in: dir)
        queue.enqueue(urls: [url], mode: .plain)
        try await waitUntilIdle(queue)
        queue.clearFinished()

        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - Memória

    @Test("Modo texto corrido descarta samples; reunião mantém para tocar trechos")
    func trimsSamplesOnlyForPlainMode() {
        let heavy = makeResult(text: "oi", fileName: "a.wav", samples: Array(repeating: 0.5, count: 16_000))

        let plain = FileTranscriptionQueue.trimmedForStorage(heavy, mode: .plain)
        #expect(plain.samples.isEmpty)
        #expect(plain.text == "oi")
        #expect(plain.durationSeconds == heavy.durationSeconds)

        let meeting = FileTranscriptionQueue.trimmedForStorage(heavy, mode: .meeting)
        #expect(meeting.samples.count == 16_000)
    }

    @Test("Só formatos de ffmpeg entram no prefetch de transcodificação")
    func detectsFilesNeedingTranscoding() {
        #expect(FileTranscriptionQueue.needsTranscoding(URL(fileURLWithPath: "/tmp/a.opus")))
        #expect(FileTranscriptionQueue.needsTranscoding(URL(fileURLWithPath: "/tmp/a.OGG")))
        #expect(FileTranscriptionQueue.needsTranscoding(URL(fileURLWithPath: "/tmp/a.wav")) == false)
        #expect(FileTranscriptionQueue.needsTranscoding(URL(fileURLWithPath: "/tmp/a.m4a")) == false)
    }
}
