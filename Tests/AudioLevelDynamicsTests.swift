import Foundation
import Testing
@testable import zspeak

@Suite("AudioLevelDynamics")
struct AudioLevelDynamicsTests {

    @Test("Normalizacao RMS preserva dinamica de fala sem saturar cedo")
    func normalizacaoPreservaDinamica() {
        let silencio = AudioLevelNormalizer.normalizedRMS(0.0001)
        let falaMedia = AudioLevelNormalizer.normalizedRMS(0.02)
        let falaAlta = AudioLevelNormalizer.normalizedRMS(0.10)

        #expect(silencio == 0)
        #expect(falaMedia > 0.35)
        #expect(falaMedia < 0.75)
        #expect(falaAlta > falaMedia)
        #expect(falaAlta < 1)
    }

    @Test("Waveform responde rapido na subida e decai sem apagar instantaneamente")
    func waveformAttackRelease() {
        let subida = WaveformDynamics.nextDisplayLevel(rawLevel: 0.70, previousLevel: 0)
        let queda = WaveformDynamics.nextDisplayLevel(rawLevel: 0, previousLevel: subida)

        #expect(subida > 0.40)
        #expect(subida <= 1)
        #expect(queda < subida)
        #expect(queda > 0)
    }

    @Test("Historico mantem apenas a capacidade configurada")
    func historicoRespeitaCapacidade() {
        let history = WaveformDynamics.appending(0.4, to: [0.1, 0.2, 0.3], capacity: 3)

        #expect(history == [0.2, 0.3, 0.4])
    }
}
