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

    @Test("Waveform estilo ChatGPT responde ao volume sem saltos visuais")
    func chatGPTWaveformDynamics() {
        let silenceHistory = Array(repeating: Float(0), count: 32)
        let activeHistory: [Float] = [
            0.05, 0.08, 0.20, 0.34, 0.58, 0.78, 0.62, 0.44,
            0.36, 0.52, 0.70, 0.64, 0.40, 0.24, 0.18, 0.12,
            0.10, 0.22, 0.42, 0.66, 0.84, 0.72, 0.48, 0.30,
            0.20, 0.32, 0.54, 0.68, 0.50, 0.28, 0.14, 0.08
        ]
        let silentHeight = WaveformDynamics.chatGPTWaveformBarHeight(
            index: 16,
            count: 32,
            level: 0,
            history: silenceHistory,
            phase: 1.0,
            minimumHeight: 4,
            maximumHeight: 30
        )
        let activeHeight = WaveformDynamics.chatGPTWaveformBarHeight(
            index: 16,
            count: 32,
            level: 0.72,
            history: activeHistory,
            phase: 1.0,
            minimumHeight: 4,
            maximumHeight: 30
        )
        let activeEnergy = WaveformDynamics.chatGPTWaveformBarEnergy(
            index: 16,
            count: 32,
            level: 0.72,
            history: activeHistory,
            phase: 1.0
        )
        let nextFrameEnergy = WaveformDynamics.chatGPTWaveformBarEnergy(
            index: 16,
            count: 32,
            level: 0.72,
            history: activeHistory,
            phase: 1.1
        )
        let leftEnergy = WaveformDynamics.chatGPTWaveformBarEnergy(
            index: 4,
            count: 32,
            level: 0.72,
            history: activeHistory,
            phase: 1.0
        )
        let opacity = WaveformDynamics.chatGPTWaveformBarOpacity(
            index: 16,
            count: 32,
            energy: activeEnergy
        )

        #expect(activeHeight > silentHeight + 8)
        #expect(activeHeight <= 30)
        #expect(silentHeight >= 4)
        #expect(abs(activeEnergy - nextFrameEnergy) < 0.08)
        #expect(abs(activeEnergy - leftEnergy) > 0.07)
        #expect(opacity > 0.5)
        #expect(opacity <= 0.96)
    }
}
