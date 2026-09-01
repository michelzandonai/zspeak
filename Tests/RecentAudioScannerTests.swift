import Foundation
import Testing

@testable import zspeak

/// Cobre a lista de áudios recentes da pasta de downloads: é por onde o usuário
/// pega os áudios que acabou de baixar do WhatsApp.
@Suite("RecentAudioScanner")
struct RecentAudioScannerTests {

    private func makeFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Cria o arquivo. A data de chegada na pasta é carimbada pelo kernel e NÃO
    /// dá para forjar — por isso a ordenação é testada em `sorted(_:limit:)`, e
    /// o que se testa no disco é a ordem real de criação.
    @discardableResult
    private func makeFile(_ name: String, in folder: URL, at date: Date, bytes: Int = 1024) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        try FileManager.default.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: url.path)
        return url
    }

    private let base = Date(timeIntervalSince1970: 1_780_000_000)

    // MARK: - Ordenação

    private func entry(_ name: String, _ date: Date, bytes: Int64 = 1024) -> RecentAudioScanner.Entry {
        RecentAudioScanner.Entry(
            url: URL(fileURLWithPath: "/tmp/\(name)"),
            fileName: name,
            arrivedAt: date,
            sizeBytes: bytes
        )
    }

    @Test("Ordena do mais novo para o mais antigo")
    func sortsNewestFirst() {
        let ordered = RecentAudioScanner.sorted([
            entry("antigo.ogg", base.addingTimeInterval(-7200)),
            entry("novo.ogg", base),
            entry("meio.ogg", base.addingTimeInterval(-3600)),
        ])

        #expect(ordered.map(\.fileName) == ["novo.ogg", "meio.ogg", "antigo.ogg"])
    }

    @Test("Empate de data é desempatado pelo nome, para a ordem não dançar")
    func breaksTiesByName() {
        let ordered = RecentAudioScanner.sorted([
            entry("b.ogg", base),
            entry("a.ogg", base),
        ])

        #expect(ordered.map(\.fileName) == ["a.ogg", "b.ogg"])
    }

    @Test("Ordenação corta pelo teto mantendo os mais novos")
    func sortedHonorsLimit() {
        let ordered = RecentAudioScanner.sorted(
            (0..<10).map { entry("audio-\($0).ogg", base.addingTimeInterval(Double($0) * 60)) },
            limit: 3
        )

        #expect(ordered.map(\.fileName) == ["audio-9.ogg", "audio-8.ogg", "audio-7.ogg"])
    }

    @Test("No disco, o arquivo que chegou por último vem primeiro")
    func newestArrivalComesFirstOnDisk() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        try makeFile("primeiro.ogg", in: folder, at: base)
        try makeFile("segundo.ogg", in: folder, at: base)
        try makeFile("terceiro.ogg", in: folder, at: base)

        let entries = RecentAudioScanner.scan(directory: folder)

        #expect(entries.map(\.fileName) == ["terceiro.ogg", "segundo.ogg", "primeiro.ogg"])
    }

    @Test("Áudio antigo baixado agora aparece no topo")
    func arrivalBeatsCreationDate() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        // Chega primeiro, mas com data de gravação recente.
        try makeFile("gravado-hoje.ogg", in: folder, at: base)
        // Chega depois, com data de gravação de um ano atrás — é o caso real do
        // WhatsApp: áudio velho encaminhado e baixado agora.
        try makeFile("gravado-ano-passado.ogg", in: folder, at: base.addingTimeInterval(-365 * 24 * 3600))

        let entries = RecentAudioScanner.scan(directory: folder)

        #expect(entries.first?.fileName == "gravado-ano-passado.ogg")
    }

    @Test("Varredura respeita o teto da lista")
    func scanHonorsLimit() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        for index in 0..<10 {
            try makeFile("audio-\(index).ogg", in: folder, at: base)
        }

        #expect(RecentAudioScanner.scan(directory: folder, limit: 3).count == 3)
    }

    // MARK: - Filtragem

    @Test("Só entra o que o transcritor sabe abrir")
    func filtersUnsupportedFiles() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        try makeFile("nota.ogg", in: folder, at: base)
        try makeFile("planilha.xlsx", in: folder, at: base)
        try makeFile("foto.png", in: folder, at: base)
        try makeFile("recibo.pdf", in: folder, at: base)

        let entries = RecentAudioScanner.scan(directory: folder)

        #expect(entries.map(\.fileName) == ["nota.ogg"])
    }

    @Test("Extensão em maiúscula continua valendo")
    func acceptsUppercaseExtension() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        try makeFile("AUDIO.OGG", in: folder, at: base)

        #expect(RecentAudioScanner.scan(directory: folder).count == 1)
    }

    @Test("Subpasta não vira item da lista")
    func ignoresDirectories() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("pasta.ogg"),
            withIntermediateDirectories: true
        )
        try makeFile("real.ogg", in: folder, at: base)

        #expect(RecentAudioScanner.scan(directory: folder).map(\.fileName) == ["real.ogg"])
    }

    @Test("Pasta inexistente devolve lista vazia em vez de estourar")
    func missingFolderIsEmpty() {
        let ghost = URL(fileURLWithPath: "/tmp/zspeak-nao-existe-\(UUID().uuidString)")
        #expect(RecentAudioScanner.scan(directory: ghost).isEmpty)
    }

    @Test("Tamanho do arquivo vem preenchido")
    func reportsFileSize() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        try makeFile("audio.ogg", in: folder, at: base, bytes: 4096)
        let entry = try #require(RecentAudioScanner.scan(directory: folder).first)

        #expect(entry.sizeBytes == 4096)
    }

    // MARK: - Rótulo de data e hora

    private func calendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Sao_Paulo")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar().date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    @Test("Hoje mostra 'Hoje' e a hora")
    func labelsToday() {
        let now = date(2026, 8, 31, 21, 0)
        let arrived = date(2026, 8, 31, 15, 14)

        let label = RecentAudioScanner.arrivalLabel(for: arrived, now: now, calendar: calendar(), locale: Locale(identifier: "pt_BR"))

        #expect(label == "Hoje 15:14")
    }

    @Test("Ontem mostra 'Ontem' e a hora")
    func labelsYesterday() {
        let now = date(2026, 8, 31, 9, 0)
        let arrived = date(2026, 8, 30, 20, 26)

        let label = RecentAudioScanner.arrivalLabel(for: arrived, now: now, calendar: calendar(), locale: Locale(identifier: "pt_BR"))

        #expect(label == "Ontem 20:26")
    }

    @Test("Mesmo ano mostra dia/mês e hora, sem o ano")
    func labelsSameYear() {
        let now = date(2026, 8, 31, 9, 0)
        let arrived = date(2026, 3, 4, 8, 5)

        let label = RecentAudioScanner.arrivalLabel(for: arrived, now: now, calendar: calendar(), locale: Locale(identifier: "pt_BR"))

        #expect(label == "04/03 08:05")
    }

    @Test("Ano diferente mostra o ano")
    func labelsOtherYear() {
        let now = date(2026, 8, 31, 9, 0)
        let arrived = date(2025, 12, 24, 19, 30)

        let label = RecentAudioScanner.arrivalLabel(for: arrived, now: now, calendar: calendar(), locale: Locale(identifier: "pt_BR"))

        #expect(label == "24/12/2025 19:30")
    }
}
