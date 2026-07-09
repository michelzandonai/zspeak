import AppKit
import Foundation
import Testing
@testable import zspeak

/// Persistência de posição do OverlayPanel.
///
/// Bug protegido: a posição era salva como origem inferior-esquerda, mas o
/// painel redimensiona ancorado no TOPO e o init usa uma altura fixa (80pt)
/// diferente da altura do conteúdo no momento do save. Resultado: a cada
/// relaunch o overlay "descia" pela diferença de altura, acumulando o desvio.
/// A âncora persistida agora é o canto superior esquerdo (`frame.maxY`),
/// invariante em todos os resizes programáticos.
@Suite("OverlayPanelPosition", .serialized)
@MainActor
struct OverlayPanelPositionTests {

    private static let xKey = "overlayPanelX"
    private static let legacyYKey = "overlayPanelY"
    private static let topYKey = "overlayPanelTopY"

    /// Limpa os defaults de posição e retorna os valores originais do usuário
    /// para restauração ao final (os testes usam o domínio real).
    private func clearPositionDefaults() -> [(String, Any?)] {
        let defaults = UserDefaults.standard
        let saved = [Self.xKey, Self.legacyYKey, Self.topYKey].map {
            ($0, defaults.object(forKey: $0))
        }
        for (key, _) in saved { defaults.removeObject(forKey: key) }
        return saved
    }

    private func restorePositionDefaults(_ saved: [(String, Any?)]) {
        let defaults = UserDefaults.standard
        for (key, value) in saved {
            if let value {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
    }

    /// Executa `body` com os defaults de posição limpos, restaurando ao final.
    private func withCleanPositionDefaults(_ body: () throws -> Void) rethrows {
        let saved = clearPositionDefaults()
        defer { restorePositionDefaults(saved) }
        try body()
    }

    /// Posição garantidamente dentro da área visível (sobrevive ao clamp)
    /// para um painel de até `size`. Coordenadas inteiras: o AppKit pode
    /// ajustar origens fracionárias ao posicionar a janela.
    private func onScreenTopLeft(for size: NSSize = NSSize(width: 520, height: 240)) -> NSPoint {
        let visible = NSScreen.main!.visibleFrame.insetBy(dx: 16, dy: 16)
        return NSPoint(
            x: (visible.midX - size.width / 2).rounded(),
            y: (visible.midY + size.height / 2).rounded()
        )
    }

    @Test("Restaura pela âncora do topo, independente da altura do init")
    func restauraPeloTopo() throws {
        try withCleanPositionDefaults {
            let defaults = UserDefaults.standard
            let target = onScreenTopLeft()
            defaults.set(Double(target.x), forKey: Self.xKey)
            defaults.set(Double(target.y), forKey: Self.topYKey)

            let panel = OverlayPanel()

            #expect(abs(panel.frame.maxY - target.y) < 0.5)
            #expect(abs(panel.frame.origin.x - target.x) < 0.5)
        }
    }

    @Test("Migra a chave legada (origem inferior) preservando o comportamento antigo")
    func migraChaveLegada() throws {
        try withCleanPositionDefaults {
            let defaults = UserDefaults.standard
            let target = onScreenTopLeft()
            defaults.set(Double(target.x), forKey: Self.xKey)
            defaults.set(Double(target.y - 240), forKey: Self.legacyYKey)

            let panel = OverlayPanel()

            // Formato antigo: a base restaurada + altura do init define o topo.
            #expect(abs(panel.frame.origin.y - (target.y - 240)) < 0.5)
            #expect(abs(panel.frame.origin.x - target.x) < 0.5)
        }
    }

    @Test("Mover o painel persiste o topo e remove a chave legada")
    func movePersisteTopo() throws {
        try withCleanPositionDefaults {
            let defaults = UserDefaults.standard
            defaults.set(123.0, forKey: Self.legacyYKey)
            let panel = OverlayPanel()

            let target = onScreenTopLeft(for: panel.frame.size)
            panel.setFrameOrigin(NSPoint(x: target.x, y: target.y - panel.frame.height))

            #expect(abs(defaults.double(forKey: Self.xKey) - target.x) < 0.5)
            #expect(abs(defaults.double(forKey: Self.topYKey) - target.y) < 0.5)
            #expect(defaults.object(forKey: Self.legacyYKey) == nil)
        }
    }

    @Test("Resize ancorado no topo não altera a posição persistida")
    func resizeNaoCorrompePosicao() throws {
        try withCleanPositionDefaults {
            let defaults = UserDefaults.standard
            let panel = OverlayPanel()
            let target = onScreenTopLeft(for: NSSize(width: 520, height: 240))
            panel.setFrameOrigin(NSPoint(x: target.x, y: target.y - panel.frame.height))
            let topBefore = defaults.double(forKey: Self.topYKey)

            // Simula o que adjustToPreferredSize faz a cada mudança de estado:
            // cresce para baixo mantendo o topo fixo.
            var grown = panel.frame
            grown.origin.y -= 120
            grown.size.height += 120
            panel.setFrame(grown, display: false)

            #expect(abs(defaults.double(forKey: Self.topYKey) - topBefore) < 0.5)
        }
    }

    /// Espera `condition` virar true cedendo o MainActor entre checagens —
    /// necessário para completions de animação e Tasks internas rodarem
    /// (um teste @MainActor síncrono bloquearia a fila principal).
    private func waitUntil(
        _ condition: @autoclosure () -> Bool,
        timeout: TimeInterval = 15
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    // Regressão da "descida a cada gravação": o hide() antigo capturava a
    // origem inferior ANTES do fade e a restaurava no fim — mas durante o fade
    // o conteúdo relayouta para o estado idle (altura menor, topo fixo), então
    // a restauração deslocava o topo para baixo pela diferença de altura, a
    // cada ciclo. Agora todo reposicionamento deriva da âncora do topo.
    @Test("Ciclos de show/hide com relayout durante o fade não deslocam o overlay")
    func showHideCyclesNaoDeslocam() async throws {
        let saved = clearPositionDefaults()
        defer { restorePositionDefaults(saved) }

        let panel = OverlayPanel()
        // Força os caminhos ANIMADOS (rise-in/drift): no xctest headless o
        // Reduce Motion reporta true e a regressão não seria exercitada.
        panel.prefersReducedMotion = { false }
        let target = onScreenTopLeft()
        panel.setFrameOrigin(NSPoint(x: target.x, y: target.y - panel.frame.height))
        let expectedTop = panel.frame.maxY

        for _ in 0..<3 {
            panel.show()
            // Aguarda o rise-in terminar (dispatch async + 0.26s de animação).
            await waitUntil(panel.isVisible && panel.alphaValue >= 1)

            // Sessão de gravação: conteúdo cresce mantendo o topo.
            var grown = panel.frame
            grown.origin.y -= 160
            grown.size.height += 160
            panel.setFrame(grown, display: false)

            panel.hide()
            // Relayout para idle DURANTE o fade — encolhe mantendo o topo.
            var shrunk = panel.frame
            shrunk.origin.y += 160
            shrunk.size.height -= 160
            panel.setFrame(shrunk, display: false)
            await waitUntil(!panel.isVisible)
        }

        #expect(!panel.isVisible)
        #expect(abs(panel.frame.maxY - expectedTop) < 1.0)
        #expect(abs(panel.frame.origin.x - target.x) < 1.0)
    }

    @Test("Round-trip de relaunch mantém o overlay onde o usuário deixou")
    func relaunchNaoDesloca() throws {
        try withCleanPositionDefaults {
            // Sessão 1: painel expandido (gravação)...
            let target = onScreenTopLeft()
            let session1 = OverlayPanel()
            var expanded = session1.frame
            expanded.size = NSSize(width: 520, height: 240)
            session1.setFrame(expanded, display: false)
            // ...arrastado pelo usuário (só a origem muda — é o que dispara
            // didMove e persiste a posição, como no drag real).
            session1.setFrameOrigin(NSPoint(x: target.x, y: target.y - 240))
            let topSession1 = session1.frame.maxY

            // "Relaunch": o init nasce com contentRect de 80pt de altura.
            let session2 = OverlayPanel()

            #expect(abs(session2.frame.maxY - topSession1) < 0.5)
            #expect(abs(session2.frame.origin.x - target.x) < 0.5)
        }
    }
}
