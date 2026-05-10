import Foundation
import Testing
@testable import zspeak

@Suite("Prompt - Clareza sem vicios")
struct LanguageCleanupPromptTests {

    @Test("Roda nos textos recentes de benchmark/historico")
    @MainActor
    func testLanguageCleanupOnRecentSamples() async throws {
        let manager = LLMCorrectionManager()
        guard await manager.checkModelExists() else {
            print("SKIP: modelo LLM nao baixado")
            return
        }

        try await manager.loadModel()
        guard case .ready = await manager.modelState else {
            print("SKIP: modelo LLM nao carregou")
            return
        }

        let samples = [
            "Cria um prompt específico para tirar vícios de linguagem, ou informações que eu estou passando que não fazem muito sentido, enfim. Deixar mais claro e mais sucinto. Basicamente, esse é o prompt que eu quero que você crie para que eu consiga utilizar aqui.",
            "Eu peço para que você utilize como teste nos últimos branchmarks o que foi gerado e faça teste para verificar se realmente está legal o pront.",
            "When I ativar the mode prompt, no personal button to apply, no, automatically just deve iron com a conversion. So I think visualize what was transcrito e a conversion. I'm going to visualize this, but apparently what to feel deuce.",
        ]

        for sample in samples {
            let result = try await manager.correct(
                text: sample,
                systemPrompt: CorrectionPromptStore.languageCleanupSystemPrompt,
                maxTokens: 512
            )

            print("INPUT:", sample)
            print("OUTPUT:", result)
            print("")

            let normalized = result.lowercased()
            #expect(!result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(!normalized.contains("enfim"))
            #expect(!normalized.contains("basicamente"))
            #expect(!normalized.contains("branchmarks"))
            #expect(!normalized.contains("sucrossom"))
            #expect(result.count <= sample.count + 40)
        }
    }
}
