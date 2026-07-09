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

    @Test("Rolagem da waveform é contínua entre amostras")
    func scrollContinuity() {
        let pitch: CGFloat = 6.5
        let right: CGFloat = 300

        // Fim de um intervalo == início do próximo (a barra "envelhece" uma
        // posição sem saltar quando a amostra nova chega).
        let endOfInterval = WaveformDynamics.scrollingBarX(
            distanceFromNewest: 3,
            sampleProgress: 1,
            pitch: pitch,
            rightmostX: right
        )
        let startOfNext = WaveformDynamics.scrollingBarX(
            distanceFromNewest: 4,
            sampleProgress: 0,
            pitch: pitch,
            rightmostX: right
        )

        #expect(endOfInterval == startOfNext)
        // A barra mais recente nasce na borda direita.
        #expect(
            WaveformDynamics.scrollingBarX(
                distanceFromNewest: 0,
                sampleProgress: 0,
                pitch: pitch,
                rightmostX: right
            ) == right
        )
    }

    @Test("Altura da barra cresce com o nível e respeita os limites")
    func barHeightFollowsLevel() {
        let silent = WaveformDynamics.scrollingBarHeight(level: 0, minimumHeight: 3, maximumHeight: 34)
        let medium = WaveformDynamics.scrollingBarHeight(level: 0.5, minimumHeight: 3, maximumHeight: 34)
        let loud = WaveformDynamics.scrollingBarHeight(level: 1, minimumHeight: 3, maximumHeight: 34)
        let overdriven = WaveformDynamics.scrollingBarHeight(level: 2, minimumHeight: 3, maximumHeight: 34)

        #expect(silent == 3)
        #expect(medium > silent + 8)
        #expect(loud > medium)
        #expect(loud == 34)
        #expect(overdriven == 34)
    }

    @Test("Opacidade favorece barras recentes e nunca estoura")
    func barOpacityGradient() {
        let newest = WaveformDynamics.scrollingBarOpacity(level: 0.6, positionProgress: 1)
        let oldest = WaveformDynamics.scrollingBarOpacity(level: 0.6, positionProgress: 0)

        #expect(newest > oldest)
        #expect(oldest >= 0.25)
        #expect(WaveformDynamics.scrollingBarOpacity(level: 1, positionProgress: 1) <= 0.97)
    }

    @Test("Respiração idle é sutil, positiva e determinística")
    func idleBreathIsSubtle() {
        for slot in 0..<64 {
            let value = WaveformDynamics.idleBreathLevel(slot: slot, phase: 1.7)
            #expect(value > 0)
            #expect(value < 0.09)
        }
        #expect(
            WaveformDynamics.idleBreathLevel(slot: 5, phase: 2.0)
                == WaveformDynamics.idleBreathLevel(slot: 5, phase: 2.0)
        )
    }

    @Test("Suavização 3-tap conecta vizinhas sem apagar picos")
    func smoothedProfileConnectsNeighbors() {
        let jagged: [Float] = [0, 0.9, 0, 0.9, 0]
        let smoothed = WaveformDynamics.smoothedProfile(jagged)

        #expect(smoothed.count == jagged.count)
        // Extremidades intactas; vales sobem e picos descem — perfil de onda.
        #expect(smoothed[0] == 0)
        #expect(smoothed[4] == 0)
        #expect(smoothed[2] > 0.3)
        #expect(smoothed[1] < 0.9)
        #expect(smoothed[1] > 0.4)
        // Entradas curtas passam intocadas.
        #expect(WaveformDynamics.smoothedProfile([0.5, 0.7]) == [0.5, 0.7])
        #expect(WaveformDynamics.smoothedProfile([]).isEmpty)
    }

    @Test("Boost de recência decai e zera fora da cabeça")
    func recencyBoostDecays() {
        let newest = WaveformDynamics.recencyBoost(distanceFromNewest: 0)
        let mid = WaveformDynamics.recencyBoost(distanceFromNewest: 2)
        let outside = WaveformDynamics.recencyBoost(distanceFromNewest: 8)

        #expect(newest == 0.25)
        #expect(mid < newest)
        #expect(mid > 0)
        #expect(outside == 0)
    }

    @Test("Lampejo de ataque acende a cabeça e decai; silêncio não acende nada")
    func onsetBoostFlashesOnAttack() {
        let headOnAttack = WaveformDynamics.onsetBoost(attack: 0.4, distanceFromNewest: 0)
        let midOnAttack = WaveformDynamics.onsetBoost(attack: 0.4, distanceFromNewest: 2)
        let outside = WaveformDynamics.onsetBoost(attack: 0.4, distanceFromNewest: 8)
        let noAttack = WaveformDynamics.onsetBoost(attack: 0, distanceFromNewest: 0)
        let release = WaveformDynamics.onsetBoost(attack: -0.3, distanceFromNewest: 0)

        #expect(abs(headOnAttack - 0.2) < 0.0001)
        #expect(midOnAttack < headOnAttack)
        #expect(midOnAttack > 0)
        #expect(outside == 0)
        #expect(noAttack == 0)
        // Queda de nível (release) não gera lampejo.
        #expect(release == 0)
        // Ataque máximo continua dentro do teto de opacidade.
        #expect(WaveformDynamics.onsetBoost(attack: 1, distanceFromNewest: 0) == 0.5)
    }

    @Test("Nível interpolado flui entre amostras e clampa nas bordas")
    func interpolatedLevelFlows() {
        let midpoint = WaveformDynamics.interpolatedLevel(previous: 0.2, current: 0.8, progress: 0.5)
        let start = WaveformDynamics.interpolatedLevel(previous: 0.2, current: 0.8, progress: 0)
        let end = WaveformDynamics.interpolatedLevel(previous: 0.2, current: 0.8, progress: 1)
        let overshoot = WaveformDynamics.interpolatedLevel(previous: 0.2, current: 0.8, progress: 2)

        #expect(abs(midpoint - 0.5) < 0.0001)
        #expect(start == 0.2)
        #expect(end == 0.8)
        #expect(overshoot == 0.8)
    }

    @Test("Waveform preserva as diferenças das amostras reais da voz")
    func waveformFollowsRealAudioSamples() {
        let quiet = WaveformDynamics.audioDrivenLevel(sampleLevel: 0.10, idleLevel: 0.04)
        let loud = WaveformDynamics.audioDrivenLevel(sampleLevel: 0.82, idleLevel: 0.04)
        let idle = WaveformDynamics.audioDrivenLevel(sampleLevel: 0, idleLevel: 0.04)

        #expect(quiet == 0.10)
        #expect(loud == 0.82)
        #expect(loud > quiet * 5)
        #expect(idle == 0.04)
    }

    @Test("Fita luminosa mantém a dinâmica da voz e os limites visuais")
    func ribbonAmplitudeFollowsAudioLevel() {
        let silent = WaveformDynamics.ribbonAmplitude(
            level: 0,
            minimumAmplitude: 2,
            maximumAmplitude: 16
        )
        let quiet = WaveformDynamics.ribbonAmplitude(
            level: 0.12,
            minimumAmplitude: 2,
            maximumAmplitude: 16
        )
        let loud = WaveformDynamics.ribbonAmplitude(
            level: 0.82,
            minimumAmplitude: 2,
            maximumAmplitude: 16
        )
        let saturated = WaveformDynamics.ribbonAmplitude(
            level: 2,
            minimumAmplitude: 2,
            maximumAmplitude: 16
        )

        #expect(silent == 2)
        #expect(quiet > silent)
        #expect(loud > quiet + 5)
        #expect(saturated == 16)
    }

    @Test("Controles da fita mantêm o avanço horizontal suave")
    func ribbonBezierControlsPreserveForwardFlow() {
        let controls = WaveformDynamics.ribbonBezierControls(
            previous: CGPoint(x: 0, y: 10),
            current: CGPoint(x: 10, y: 3),
            next: CGPoint(x: 20, y: 16),
            following: CGPoint(x: 30, y: 8)
        )

        #expect(controls.first.x > 10)
        #expect(controls.first.x < 20)
        #expect(controls.second.x > 10)
        #expect(controls.second.x < 20)
    }

    @Test("Histórico sintético de snapshots é determinístico e escala com o nível")
    func syntheticHistoryDeterministic() {
        let first = WaveformDynamics.syntheticSpeechHistory(count: 53, level: 0.56, phase: 0.42)
        let second = WaveformDynamics.syntheticSpeechHistory(count: 53, level: 0.56, phase: 0.42)
        let quiet = WaveformDynamics.syntheticSpeechHistory(count: 53, level: 0.1, phase: 0.42)

        #expect(first == second)
        #expect(first.count == 53)
        #expect(first.allSatisfy { $0 >= 0 && $0 <= 1 })
        #expect(first.max()! > quiet.max()!)
        #expect(WaveformDynamics.syntheticSpeechHistory(count: 0, level: 1, phase: 0).isEmpty)
    }

    // MARK: - Grade de amostragem agendada

    @Test("Slots pendentes seguem a grade de tempo")
    func pendingSlotsFollowGrid() {
        let period = 0.045
        // Acordou exatamente no deadline → 1 amostra.
        #expect(WaveformDynamics.pendingSampleSlots(
            scheduledLastSampleAt: 0, now: period, samplePeriod: period, maximumSlots: 53) == 1)
        // Acordou cedo (antes de um período completo) → nada a registrar.
        #expect(WaveformDynamics.pendingSampleSlots(
            scheduledLastSampleAt: 0, now: period * 0.9, samplePeriod: period, maximumSlots: 53) == 0)
        // Stall de 3,5 períodos → 3 amostras de catch-up.
        #expect(WaveformDynamics.pendingSampleSlots(
            scheduledLastSampleAt: 0, now: period * 3.5, samplePeriod: period, maximumSlots: 53) == 3)
        // Stall gigante → capado na capacidade visível.
        #expect(WaveformDynamics.pendingSampleSlots(
            scheduledLastSampleAt: 0, now: 60, samplePeriod: period, maximumSlots: 53) == 53)
        // Entradas degeneradas.
        #expect(WaveformDynamics.pendingSampleSlots(
            scheduledLastSampleAt: 10, now: 5, samplePeriod: period, maximumSlots: 53) == 0)
        #expect(WaveformDynamics.pendingSampleSlots(
            scheduledLastSampleAt: 0, now: 1, samplePeriod: 0, maximumSlots: 53) == 0)
    }

    // Regressão da micro-trava da rolagem: o sampler antigo dormia "período +
    // trabalho" e carimbava a amostra com o horário REAL — o atraso acumulava
    // e o sampleProgress ((now - lastSampleAt)/período, clampado em 1)
    // saturava a CADA ciclo, congelando a rolagem um instante por amostra
    // (visível com barras altas, i.e. falando). Com a grade agendada, o
    // timestamp avança em múltiplos exatos do período e o progress nunca
    // satura em regime normal, mesmo com o loop acordando atrasado.
    @Test("Grade agendada não satura o progress com sampler acordando atrasado")
    func scheduledGridKeepsScrollFlowing() {
        let period = 0.045
        let wakeupLateness = 0.009 // MainActor sob carga: acorda ~9ms depois

        var scheduledLastSampleAt = 0.0
        for _ in 0..<200 {
            let now = scheduledLastSampleAt + period + wakeupLateness
            let slots = WaveformDynamics.pendingSampleSlots(
                scheduledLastSampleAt: scheduledLastSampleAt,
                now: now,
                samplePeriod: period,
                maximumSlots: 53
            )
            #expect(slots == 1)
            scheduledLastSampleAt += Double(slots) * period

            // Invariante: logo após registrar, o relógio da rolagem retoma de
            // um progress < 1 — sem trecho saturado esperando a próxima
            // amostra (o atraso do wakeup NÃO acumula na grade).
            let progressAfterAppend = (now - scheduledLastSampleAt) / period
            #expect(progressAfterAppend < 1)
            #expect(abs(progressAfterAppend - wakeupLateness / period) < 0.0001)
        }
    }
}
