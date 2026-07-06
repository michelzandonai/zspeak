import Foundation
import Testing
@testable import zspeak

@Suite("LLMCoordinator")
struct LLMCoordinatorTests {

    // Regressão: o watchdog fixo de 120 s cancelava correções legítimas de
    // texto longo — exatamente o caso que o maxTokens escalado passou a
    // suportar. O timeout deve crescer junto com o output esperado.
    @Test("Watchdog escala com maxTokens sem cair abaixo do piso de 120s")
    func watchdogTimeoutScalesWithMaxTokens() {
        // Texto curto: piso de 120 s
        #expect(LLMCoordinator.correctionTimeout(forMaxTokens: 1_024) == 120)
        #expect(LLMCoordinator.correctionTimeout(forMaxTokens: 2_400) == 120)

        // Texto de ~10 min (≈18k chars → 6k tokens): a ~20 tok/s o MLX local
        // precisa de ~300 s — o timeout precisa acomodar
        #expect(LLMCoordinator.correctionTimeout(forMaxTokens: 6_000) == 300)
        #expect(LLMCoordinator.correctionTimeout(forMaxTokens: 12_000) == 600)
    }
}
