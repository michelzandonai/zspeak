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
        #expect(ProgressiveTextReveal.frameDelayMilliseconds(remainingCharacterCount: 12) == 13)
        #expect(ProgressiveTextReveal.frameDelayMilliseconds(remainingCharacterCount: 72) == 10)
        #expect(ProgressiveTextReveal.frameDelayMilliseconds(remainingCharacterCount: 140) == 8)
        #expect(ProgressiveTextReveal.animationDuration(remainingCharacterCount: 12) == 0.065)
        #expect(ProgressiveTextReveal.animationDuration(remainingCharacterCount: 140) == 0.040)
    }

    @Test("Separa apenas o trecho editado preservando sufixo comum")
    func revisionKeepsStableSuffix() {
        let revision = ProgressiveTextReveal.revision(
            current: "Eu quero fazer o comit dela",
            target: "Eu quero fazer o commit dela"
        )

        #expect(revision.prefix == "Eu quero fazer o com")
        #expect(revision.removed == "")
        #expect(revision.inserted == "m")
        #expect(revision.suffix == "it dela")
        #expect(revision.targetText == "Eu quero fazer o commit dela")
    }

    @Test("Mantem trecho removido visivel para apagar em passos")
    func revisionKeepsRemovedTextForSlowDeletion() {
        let revision = ProgressiveTextReveal.revision(
            current: "Hoje preciso ajustar o cub",
            target: "Hoje preciso ajustar o Kubernetes"
        )
        let firstStep = ProgressiveTextReveal.deletingText(revision.removed, maxCharacters: 1)
        let batch = ProgressiveTextReveal.deletionBatchSize(remainingCharacterCount: revision.removed.count)

        #expect(revision.prefix == "Hoje preciso ajustar o ")
        #expect(revision.removed == "cub")
        #expect(revision.inserted == "Kubernetes")
        #expect(firstStep == "cu")
        #expect(batch == 1)
        #expect(ProgressiveTextReveal.deletionFrameDelayMilliseconds(remainingCharacterCount: 3) == 28)
    }

    @Test("Espera estabilizacao antes de apagar blocos grandes")
    func delaysLargeDeletionUntilTargetStabilizes() {
        let smallRevision = ProgressiveTextReveal.Revision(
            prefix: "Hoje ",
            removed: "abc",
            inserted: "xyz",
            suffix: ""
        )
        let largeRevision = ProgressiveTextReveal.Revision(
            prefix: "Hoje ",
            removed: String(repeating: "a", count: 42),
            inserted: "",
            suffix: ""
        )
        let smallDeletionRevision = ProgressiveTextReveal.Revision(
            prefix: "Hoje ",
            removed: String(repeating: "a", count: 30),
            inserted: "",
            suffix: ""
        )

        #expect(ProgressiveTextReveal.deletionStabilizationDelayMilliseconds(for: smallRevision) == 0)
        #expect(ProgressiveTextReveal.deletionStabilizationDelayMilliseconds(for: smallDeletionRevision) == 999)
        #expect(ProgressiveTextReveal.deletionStabilizationDelayMilliseconds(for: largeRevision) == 1_400)
    }

    @Test("Segura apagao de texto inteiro ate chegar revisao completa")
    func holdsWholeTextDiscontinuityUntilCompleteRevision() {
        let collapsedPreview = ProgressiveTextReveal.Revision(
            prefix: "",
            removed: String(repeating: "a", count: 160),
            inserted: "ok",
            suffix: ""
        )
        let completeReplacement = ProgressiveTextReveal.Revision(
            prefix: "",
            removed: String(repeating: "a", count: 160),
            inserted: String(repeating: "b", count: 150),
            suffix: ""
        )

        #expect(ProgressiveTextReveal.isWholeTextDiscontinuity(collapsedPreview))
        #expect(ProgressiveTextReveal.wholeTextDiscontinuityDelayMilliseconds(for: collapsedPreview) == 2_800)
        #expect(ProgressiveTextReveal.wholeTextDiscontinuityRetryDelayMilliseconds == 1_000)
        #expect(!ProgressiveTextReveal.isWholeTextDiscontinuity(completeReplacement))
        #expect(ProgressiveTextReveal.wholeTextDiscontinuityDelayMilliseconds(for: completeReplacement) == 0)
    }
}
