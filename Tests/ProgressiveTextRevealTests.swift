import Testing
@testable import zspeak

@Suite("ProgressiveTextReveal")
struct ProgressiveTextRevealTests {

    @Test("Mantem texto atual quando o alvo apenas acrescenta letras")
    func keepsCurrentWhenTargetAppends() {
        let start = ProgressiveTextReveal.startText(
            current: "Hoje preciso",
            target: "Hoje preciso ajustar o deploy"
        )

        #expect(start == "Hoje preciso")
    }

    @Test("Volta ao prefixo comum quando o ASR corrige trecho anterior")
    func returnsCommonPrefixWhenTargetRewrites() {
        let start = ProgressiveTextReveal.startText(
            current: "Hoje preciso ajustar o cub",
            target: "Hoje preciso ajustar o Kubernetes"
        )

        #expect(start == "Hoje preciso ajustar o ")
    }

    @Test("Revela respeitando caracteres compostos")
    func revealsGraphemeClusters() {
        let next = ProgressiveTextReveal.nextText(
            current: "a",
            target: "ação pronta",
            maxCharacters: 1
        )

        #expect(next == "aç")
        #expect(next.count == 2)
    }

    @Test("Acelera saltos longos dentro do orçamento de frames")
    func batchesLongJumps() {
        #expect(ProgressiveTextReveal.batchSize(remainingCharacterCount: 12) == 1)
        #expect(ProgressiveTextReveal.batchSize(remainingCharacterCount: 72) == 2)
        #expect(ProgressiveTextReveal.batchSize(remainingCharacterCount: 0) == 0)
    }

    @Test("Ajusta a cadencia conforme o tamanho do salto")
    func adaptsFrameCadence() {
        #expect(ProgressiveTextReveal.frameDelayMilliseconds(remainingCharacterCount: 12) == 32)
        #expect(ProgressiveTextReveal.frameDelayMilliseconds(remainingCharacterCount: 72) == 26)
        #expect(ProgressiveTextReveal.frameDelayMilliseconds(remainingCharacterCount: 140) == 20)
    }

    // Regressão de jank: a cadencia de digitacao nunca pode voltar aos ~80-125
    // passos/s (delay < 20ms) — cada passo é relayout no MainActor e disputa
    // com a waveform de 60fps enquanto o usuário fala.
    @Test("Cadencia da digitacao fica abaixo de ~50 passos por segundo")
    func typingCadenceStaysBelowMainActorBudget() {
        for remaining in [1, 24, 25, 96, 97, 500] {
            #expect(ProgressiveTextReveal.frameDelayMilliseconds(remainingCharacterCount: remaining) >= 20)
        }
    }

    // MARK: - revealStep (correção no lugar + digitação só da cauda nova)

    @Test("Append puro digita apenas o acréscimo")
    func revealStepTypesOnlyAppendedTail() {
        let step = ProgressiveTextReveal.revealStep(
            current: "Hoje preciso",
            target: "Hoje preciso ajustar o deploy"
        )

        #expect(step.base == "Hoje preciso")
        #expect(step.tail == " ajustar o deploy")
    }

    // Regressão do bug "apaga tudo e reescreve": uma correção de pontuação no
    // meio do texto não pode derrubar o restante — troca no lugar e digita só
    // a palavra nova do fim.
    @Test("Correção interior troca no lugar sem redigitar o resto")
    func revealStepAppliesInteriorCorrectionInPlace() {
        let step = ProgressiveTextReveal.revealStep(
            current: "Tem um problema crítico? Quero resolver",
            target: "Tem um problema crítico. Quero resolver agora"
        )

        #expect(step.base == "Tem um problema crítico. Quero resolver")
        #expect(step.tail == " agora")
    }

    @Test("Palavra parcial completada continua a digitação de onde parou")
    func revealStepContinuesPartialWord() {
        let step = ProgressiveTextReveal.revealStep(
            current: "ele fica sumindo e volt",
            target: "ele fica sumindo e voltando"
        )

        #expect(step.base == "ele fica sumindo e volt")
        #expect(step.tail == "ando")
    }

    @Test("Palavra parcial trocada reaproveita o prefixo já digitado")
    func revealStepReusesTypedPrefixOfReplacedWord() {
        let step = ProgressiveTextReveal.revealStep(
            current: "quero volta",
            target: "quero voltando"
        )

        #expect(step.base == "quero volta")
        #expect(step.tail == "ndo")
    }

    @Test("Target que encolhe no fim trunca de imediato, sem redigitar")
    func revealStepTruncatesDroppedTailInstantly() {
        let step = ProgressiveTextReveal.revealStep(
            current: "quero voltar agora xpt",
            target: "quero voltar agora"
        )

        #expect(step.base == "quero voltar agora")
        #expect(step.tail == "")
    }

    @Test("Reescrita completa troca de uma vez em vez de apagar e redigitar")
    func revealStepSwapsWholeRewriteInstantly() {
        let step = ProgressiveTextReveal.revealStep(
            current: "texto antigo qualquer",
            target: "frase nova sem relação"
        )

        #expect(step.base == "frase nova sem relação")
        #expect(step.tail == "")
    }

    @Test("Texto inicial vazio é digitado por inteiro")
    func revealStepTypesFirstTextFromScratch() {
        let step = ProgressiveTextReveal.revealStep(
            current: "",
            target: "primeira frase"
        )

        #expect(step.base == "")
        #expect(step.tail == "primeira frase")
    }

    @Test("Match de palavras ignora caixa, acentos e pontuação")
    func revealStepMatchesWordsIgnoringCasePunctuation() {
        let step = ProgressiveTextReveal.revealStep(
            current: "Vou revisar o codigo, depois abro o PR",
            target: "Vou revisar o código. Depois abro o PR e aviso"
        )

        #expect(step.base == "Vou revisar o código. Depois abro o PR")
        #expect(step.tail == " e aviso")
    }
}
