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
}
