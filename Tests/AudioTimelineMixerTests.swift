import Foundation
import Testing
@testable import zspeak

@Suite("AudioTimelineMixer")
struct AudioTimelineMixerTests {
    @Test("Reprodução após silêncio longo preserva posição e ganho de fonte única")
    func delayedPlaybackAfterLongSilence() {
        let mixer = AudioTimelineMixer(origin: 10, sourceGain: 1)
        #expect(mixer.takeReady(upTo: 50).isEmpty)
        mixer.append(TimestampedAudioChunk(startTime: 50, samples: [0.6, -0.4]))
        let result = mixer.finish().samples
        #expect(result.count == 640_002)
        #expect(result.prefix(640_000).allSatisfy { $0 == 0 })
        #expect(Array(result.suffix(2)) == [0.6, -0.4])
    }

    @Test("Mistura fala e vídeo simultâneos, preservando seus horários")
    func overlapsSourcesInsteadOfConcatenating() {
        let mixer = AudioTimelineMixer(origin: 10)
        mixer.append(TimestampedAudioChunk(startTime: 10, samples: [0.8, 0.8, 0.8, 0.8]))
        mixer.append(TimestampedAudioChunk(startTime: 10 + 2 / 16_000.0, samples: [0.6, 0.6]))
        let result = mixer.finish().samples
        #expect(result.count == 4)
        #expect(abs(result[0] - 0.4) < 0.00001)
        #expect(abs(result[2] - 0.7) < 0.00001)
        #expect(abs(result[3] - 0.7) < 0.00001)
    }

    @Test("Pausas entre trechos viram silêncio, sem comprimir a conversa")
    func preservesGaps() {
        let mixer = AudioTimelineMixer(origin: 10)
        mixer.append(TimestampedAudioChunk(startTime: 10, samples: [0.4, 0.4]))
        mixer.append(TimestampedAudioChunk(startTime: 10 + 6 / 16_000.0, samples: [0.8, 0.8]))
        #expect(mixer.finish().samples == [0.2, 0.2, 0, 0, 0, 0, 0.4, 0.4])
    }

    @Test("Trecho anterior ao início não desloca o áudio gravado")
    func trimsBeforeOrigin() {
        let mixer = AudioTimelineMixer(origin: 10)
        mixer.append(TimestampedAudioChunk(startTime: 10 - 2 / 16_000.0, samples: [0.2, 0.4, 0.6, 0.8]))
        #expect(mixer.finish().samples == [0.3, 0.4])
    }

    @Test("Buffer atrasado completa texto final sem repetir o preview ao vivo")
    func lateSamplesRemainInFinalAudio() {
        let mixer = AudioTimelineMixer(origin: 10)
        mixer.append(TimestampedAudioChunk(startTime: 10, samples: [0.4, 0.4, 0.4, 0.4]))
        #expect(mixer.takeReady(upTo: 10 + 2.1 / 16_000.0) == [0.2, 0.2])
        mixer.append(TimestampedAudioChunk(startTime: 10, samples: [0.6, 0.6]))
        let final = mixer.finish()
        #expect(final.samples == [0.5, 0.5, 0.2, 0.2])
        #expect(final.remainingLiveSamples == [0.2, 0.2])
    }

    @Test("Timestamp corrompido e samples não finitos não corrompem a mistura")
    func rejectsInvalidBuffers() {
        let mixer = AudioTimelineMixer(origin: 10)
        mixer.append(TimestampedAudioChunk(startTime: .nan, samples: [1]))
        mixer.append(TimestampedAudioChunk(startTime: 1e100, samples: [1]))
        mixer.append(TimestampedAudioChunk(startTime: 1000, samples: [1]))
        mixer.append(TimestampedAudioChunk(startTime: 10, samples: [.nan, .infinity, 2, -2]))
        #expect(mixer.finish().samples == [0, 0, 0.5, -0.5])
    }

    @Test("Callbacks tardios após stop não reabrem a gravação")
    func ignoresSamplesAfterFinish() {
        let mixer = AudioTimelineMixer(origin: 10)
        mixer.append(TimestampedAudioChunk(startTime: 10, samples: [0.6]))
        #expect(mixer.finish().samples == [0.3])
        mixer.append(TimestampedAudioChunk(startTime: 10, samples: [0.8]))
        #expect(mixer.finish().samples.isEmpty)
    }

    @Test("Fala atravessa limites de páginas sem perder samples, pausas ou cauda")
    func crossesPagesAndKeepsLateSamples() {
        let mixer = AudioTimelineMixer(origin: 10)
        mixer.append(TimestampedAudioChunk(startTime: 10, samples: [Float](repeating: 0.4, count: 32_005)))
        let preview = mixer.takeReady(upTo: 11 + 5.1 / 16_000)
        #expect(preview.count == 16_005 && preview.allSatisfy { $0 == 0.2 })
        mixer.append(TimestampedAudioChunk(startTime: 11 - 2 / 16_000, samples: [0.6, 0.6, 0.6, 0.6]))
        mixer.append(TimestampedAudioChunk(startTime: 13, samples: [0.8, 0.8]))
        let final = mixer.finish()
        #expect(final.samples.count == 48_002)
        #expect(Array(final.samples[15_998..<16_002]) == [0.5, 0.5, 0.5, 0.5])
        #expect(final.samples[32_005..<48_000].allSatisfy { $0 == 0 })
        #expect(final.samples.suffix(2) == [0.4, 0.4])
        #expect(final.remainingLiveSamples == Array(final.samples[16_005...]))
        #expect(preview.allSatisfy { $0 == 0.2 }, "Callbacks tardios não mudam o preview já emitido")
    }

    @Test("Dois produtores simultâneos preservam toda a gravação entre páginas")
    func concurrentSourcesKeepAllSamples() async {
        let mixer = AudioTimelineMixer(origin: 10)
        await withTaskGroup(of: Void.self) { group in
            for value: Float in [0.4, 0.6] {
                group.addTask {
                    for index in 0..<400 {
                        mixer.append(TimestampedAudioChunk(startTime: 10 + Double(index) / 100, samples: [Float](repeating: value, count: 160)))
                    }
                }
            }
        }
        let final = mixer.finish()
        #expect(final.samples.count == 64_000)
        #expect(final.samples.allSatisfy { $0 == 0.5 })
        #expect(final.remainingLiveSamples == final.samples)
    }
}
