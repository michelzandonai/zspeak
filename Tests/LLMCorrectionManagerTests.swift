import Foundation
import Testing
@testable import zspeak

@Suite("LLMCorrectionManager - Inferencia")
struct LLMCorrectionManagerTests {

    @Test("Teste prompts variados com texto real longo")
    func testPromptVariados() async throws {
        let manager = LLMCorrectionManager()
        guard await manager.checkModelExists() else {
            print("SKIP: modelo nao baixado")
            return
        }
        try await manager.loadModel()
        guard case .ready = await manager.modelState else {
            print("SKIP: modelo nao carregou")
            return
        }

        let texto = "eu preciso configurar o servidor de deploy no kubernetes e tambem ajustar o pipeline de CI CD no github actions porque ta falhando nos testes de integracao e o banco de dados ta com latencia alta"

        // Prompt A: topicos direto
        let promptA = "Reformate o texto abaixo como lista de topicos. Use - no inicio de cada topico. Cada ideia separada deve ser um topico diferente. Nao adicione nada novo. Apenas reorganize:\n\n"

        // Prompt B: correcao pura
        let promptB = "Corrija a ortografia e pontuacao do texto abaixo. Retorne apenas o texto corrigido:"

        // Prompt C: resumo em bullets
        let promptC = "Extraia os pontos principais do texto abaixo em formato de lista com bullets (-):"

        let prompts = [("Topicos", promptA), ("Correcao", promptB), ("Bullets", promptC)]

        for (nome, prompt) in prompts {
            let result = try await manager.correct(text: texto, systemPrompt: prompt, maxTokens: 512)
            print("=== \(nome) ===")
            print(result)
            print("")
        }
    }
}
