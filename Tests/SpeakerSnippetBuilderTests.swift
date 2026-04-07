import Foundation
import Testing
@testable import zspeak

@Suite("SpeakerSnippetBuilder")
struct SpeakerSnippetBuilderTests {

    private func makeSegment(speakerId: String, start: Double, end: Double) -> TranscribedSegment {
        TranscribedSegment(
            speakerId: speakerId,
            startTimeSeconds: start,
            endTimeSeconds: end,
            text: "x"
        )
    }

    @Test("Speaker inexistente retorna vazio")
    func emptyForUnknownSpeaker() {
        let samples = Array(repeating: Float(0.1), count: 16000 * 30) // 30s
        let segments = [makeSegment(speakerId: "Speaker 0", start: 0, end: 5)]
        let snippet = SpeakerSnippetBuilder.buildSnippet(
            samples: samples,
            segments: segments,
            speakerId: "Speaker 99"
        )
        #expect(snippet.isEmpty)
    }

    @Test("Speaker com 1 segmento curto retorna o que tem")
    func singleShortSegment() {
        // 30s áudio
        let samples = Array(repeating: Float(0.5), count: 16000 * 30)
        // Segmento de 2s
        let segments = [makeSegment(speakerId: "Speaker 0", start: 5, end: 7)]
        let snippet = SpeakerSnippetBuilder.buildSnippet(
            samples: samples,
            segments: segments,
            speakerId: "Speaker 0"
        )
        // 1 pick × min(perPick=10s, 2s real) = 2s = 32000 samples
        #expect(snippet.count == 32000)
    }

    @Test("Speaker com 6 segmentos pega 3 espalhados (~10s total)")
    func threeSpreadPicks() {
        let samples = Array(repeating: Float(0.5), count: 16000 * 120) // 120s
        let segments = [
            makeSegment(speakerId: "Speaker 0", start: 0, end: 10),
            makeSegment(speakerId: "Speaker 0", start: 20, end: 30),
            makeSegment(speakerId: "Speaker 0", start: 40, end: 50),
            makeSegment(speakerId: "Speaker 0", start: 60, end: 70),
            makeSegment(speakerId: "Speaker 0", start: 80, end: 90),
            makeSegment(speakerId: "Speaker 0", start: 100, end: 110),
        ]
        let snippet = SpeakerSnippetBuilder.buildSnippet(
            samples: samples,
            segments: segments,
            speakerId: "Speaker 0"
        )
        // 3 picks × ~3.33s = ~10s = ~160000 samples
        let expected = 3 * Int((10.0 / 3.0) * 16000)
        #expect(snippet.count == expected)
    }

    @Test("Filtra segmentos de outros speakers")
    func filtersOtherSpeakers() {
        let samples = Array(repeating: Float(0.5), count: 16000 * 60)
        let segments = [
            makeSegment(speakerId: "Speaker 0", start: 0, end: 4),
            makeSegment(speakerId: "Speaker 1", start: 5, end: 10),
            makeSegment(speakerId: "Speaker 0", start: 15, end: 19),
        ]
        let snippet = SpeakerSnippetBuilder.buildSnippet(
            samples: samples,
            segments: segments,
            speakerId: "Speaker 1"
        )
        // 1 pick × 5s real (mas perPick=10s, então pega os 5 inteiros)
        #expect(snippet.count == 5 * 16000)
    }
}
