import Foundation
import Testing
import FluidAudio
@testable import zspeak

@Suite("DiarizationManager")
struct DiarizationManagerTests {

    // MARK: - mapSegments (função pura)

    @Test("mapSegments filtra segmentos vazios")
    func mapSegmentsFiltersEmpty() {
        let input: [TimedSpeakerSegment] = [
            TimedSpeakerSegment(
                speakerId: "Speaker 0",
                embedding: [],
                startTimeSeconds: 0.0,
                endTimeSeconds: 1.0,
                qualityScore: 0.9
            ),
            // Segmento zero-duration — deve ser filtrado
            TimedSpeakerSegment(
                speakerId: "Speaker 1",
                embedding: [],
                startTimeSeconds: 2.0,
                endTimeSeconds: 2.0,
                qualityScore: 0.9
            ),
            TimedSpeakerSegment(
                speakerId: "Speaker 1",
                embedding: [],
                startTimeSeconds: 3.0,
                endTimeSeconds: 5.0,
                qualityScore: 0.9
            ),
        ]

        let mapped = DiarizationManager.mapSegments(input)
        #expect(mapped.count == 2)
        #expect(mapped[0].speakerId == "Speaker 0")
        #expect(mapped[1].speakerId == "Speaker 1")
    }

    @Test("mapSegments ordena por startTimeSeconds")
    func mapSegmentsSortsByStart() {
        let input: [TimedSpeakerSegment] = [
            TimedSpeakerSegment(
                speakerId: "Speaker 1",
                embedding: [],
                startTimeSeconds: 5.0,
                endTimeSeconds: 7.0,
                qualityScore: 0.9
            ),
            TimedSpeakerSegment(
                speakerId: "Speaker 0",
                embedding: [],
                startTimeSeconds: 0.0,
                endTimeSeconds: 3.0,
                qualityScore: 0.9
            ),
            TimedSpeakerSegment(
                speakerId: "Speaker 0",
                embedding: [],
                startTimeSeconds: 3.5,
                endTimeSeconds: 4.5,
                qualityScore: 0.9
            ),
        ]

        let mapped = DiarizationManager.mapSegments(input)
        #expect(mapped.count == 3)
        #expect(mapped[0].startTimeSeconds == 0.0)
        #expect(mapped[1].startTimeSeconds == 3.5)
        #expect(mapped[2].startTimeSeconds == 5.0)
    }

    @Test("mapSegments converte Float para Double corretamente")
    func mapSegmentsConvertsTypes() {
        let input: [TimedSpeakerSegment] = [
            TimedSpeakerSegment(
                speakerId: "Speaker 0",
                embedding: [],
                startTimeSeconds: 1.5,
                endTimeSeconds: 2.75,
                qualityScore: 0.85
            )
        ]

        let mapped = DiarizationManager.mapSegments(input)
        #expect(mapped.count == 1)
        #expect(mapped[0].startTimeSeconds == 1.5)
        #expect(mapped[0].endTimeSeconds == 2.75)
        #expect(abs(mapped[0].durationSeconds - 1.25) < 0.001)
    }

    // MARK: - slice (função pura)

    @Test("slice retorna range correto")
    func sliceReturnsCorrectRange() {
        // 16 kHz × 2 segundos = 32000 samples
        let samples = Array(repeating: Float(0.5), count: 32000)

        // Slice de 0.5s a 1.5s = 16000 samples (8000..24000)
        let result = DiarizationManager.slice(
            samples: samples,
            from: 0.5,
            to: 1.5
        )

        #expect(result.count == 16000)
    }

    @Test("slice clampa bounds invalidos")
    func sliceClampsBounds() {
        let samples = Array(repeating: Float(0.5), count: 16000) // 1s

        // Tentativa de slice além do fim
        let result1 = DiarizationManager.slice(
            samples: samples,
            from: 0.5,
            to: 10.0
        )
        // Deve clampar no fim: 0.5s * 16000 = 8000; fim = 16000 → 8000 samples
        #expect(result1.count == 8000)

        // Start negativo é clampado para 0
        let result2 = DiarizationManager.slice(
            samples: samples,
            from: -5.0,
            to: 0.5
        )
        // 0..8000 = 8000 samples
        #expect(result2.count == 8000)
    }

    @Test("slice retorna vazio se range invertido")
    func sliceEmptyIfInverted() {
        let samples = Array(repeating: Float(0.1), count: 16000)
        let result = DiarizationManager.slice(samples: samples, from: 1.0, to: 0.5)
        #expect(result.isEmpty)
    }

    @Test("slice respeita sampleRate customizado")
    func sliceCustomSampleRate() {
        // 48 kHz × 1s = 48000 samples
        let samples = Array(repeating: Float(0.0), count: 48000)
        let result = DiarizationManager.slice(
            samples: samples,
            from: 0.0,
            to: 0.5,
            sampleRate: 48000
        )
        #expect(result.count == 24000)
    }

    // MARK: - SpeakerSegment

    @Test("SpeakerSegment durationSeconds calcula corretamente")
    func speakerSegmentDuration() {
        let seg = SpeakerSegment(
            speakerId: "Speaker 0",
            startTimeSeconds: 1.0,
            endTimeSeconds: 3.5
        )
        #expect(seg.durationSeconds == 2.5)
    }

    @Test("SpeakerSegment Equatable ignora ID")
    func speakerSegmentEquatable() {
        let a = SpeakerSegment(
            speakerId: "Speaker 0",
            startTimeSeconds: 1.0,
            endTimeSeconds: 3.0
        )
        let b = SpeakerSegment(
            speakerId: "Speaker 0",
            startTimeSeconds: 1.0,
            endTimeSeconds: 3.0
        )
        #expect(a == b)  // IDs diferentes mas conteúdo igual
    }

    // MARK: - computeProgress (função pura)

    @Test("computeProgress retorna 0 para 0 bytes")
    func computeProgressZero() {
        #expect(DiarizationManager.computeProgress(currentBytes: 0) == 0.0)
    }

    @Test("computeProgress calcula ratio corretamente")
    func computeProgressMid() {
        // 300 MB de 600 MB = 50%
        let result = DiarizationManager.computeProgress(currentBytes: 300_000_000)
        #expect(abs(result - 0.5) < 0.01)
    }

    @Test("computeProgress cap em 0.95")
    func computeProgressCap() {
        // 1 GB > 600 MB → cap em 0.95
        let result = DiarizationManager.computeProgress(currentBytes: 1_000_000_000)
        #expect(result == 0.95)
    }

    @Test("computeProgress respeita expected customizado")
    func computeProgressCustomExpected() {
        // 50 MB de 100 MB = 50%
        let result = DiarizationManager.computeProgress(
            currentBytes: 50_000_000,
            expected: 100_000_000
        )
        #expect(abs(result - 0.5) < 0.01)
    }

    @Test("computeProgress retorna 0 se expected for 0")
    func computeProgressInvalidExpected() {
        let result = DiarizationManager.computeProgress(
            currentBytes: 100,
            expected: 0
        )
        #expect(result == 0.0)
    }

    // MARK: - directoryByteCount (função pura)

    @Test("directoryByteCount retorna 0 para diretório inexistente")
    func directoryByteCountMissing() {
        let nonExistent = URL(fileURLWithPath: "/tmp/zspeak-non-existent-\(UUID().uuidString)")
        #expect(DiarizationManager.directoryByteCount(nonExistent) == 0)
    }

    // MARK: - makeConfig (tuning para reduzir over-segmentation)

    @Test("makeConfig usa threshold 0.7 (mais conservador que default 0.6)")
    func makeConfigThreshold() {
        let config = DiarizationManager.makeConfig()
        #expect(config.clustering.threshold == 0.7)
    }

    @Test("makeConfig com numSpeakers força exato")
    func makeConfigNumSpeakers() {
        let config = DiarizationManager.makeConfig(numSpeakers: 3)
        #expect(config.clustering.numSpeakers == 3)
    }

    @Test("makeConfig sem numSpeakers deixa nil (auto)")
    func makeConfigAuto() {
        let config = DiarizationManager.makeConfig(numSpeakers: nil)
        #expect(config.clustering.numSpeakers == nil)
    }

    @Test("makeConfig usa minGapDurationSeconds 0.5 (funde gaps curtos)")
    func makeConfigMinGap() {
        let config = DiarizationManager.makeConfig()
        #expect(config.postProcessing.minGapDurationSeconds == 0.5)
    }

    @Test("makeConfig mantém exclusiveSegments true")
    func makeConfigExclusive() {
        let config = DiarizationManager.makeConfig()
        #expect(config.postProcessing.exclusiveSegments == true)
    }

    @Test("directoryByteCount soma arquivos")
    func directoryByteCountSums() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Cria 3 arquivos de tamanho conhecido
        try Data(count: 1000).write(to: tmp.appendingPathComponent("a.bin"))
        try Data(count: 2000).write(to: tmp.appendingPathComponent("b.bin"))

        let nested = tmp.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(count: 3000).write(to: nested.appendingPathComponent("c.bin"))

        let total = DiarizationManager.directoryByteCount(tmp)
        #expect(total == 6000)
    }
}
