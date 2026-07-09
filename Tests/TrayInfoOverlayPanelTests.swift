import AppKit
import Foundation
import Testing
@testable import zspeak

/// Regressão do bug "mini-overlay desce a cada fala": o hosting view impunha
/// constraints de tamanho "ideal" (linha única sem limite) na janela e o
/// autolayout inflava o painel por baixo do setFrame manual (milhares de pt
/// de altura) — o pill, centralizado no painel inflado, descia na tela
/// conforme o texto crescia. Hoje a janela tem frame FIXO calculado uma única
/// vez por ciclo de apresentação: nada pode movê-la ou redimensioná-la entre
/// falas — qualquer deriva estoura aqui.
@Suite("TrayInfoOverlayPanel", .serialized)
@MainActor
struct TrayInfoOverlayPanelTests {

    @Test("Janela tem frame fixo por ciclo, topo pregado sob a barra de menu")
    func topStaysPinnedAcrossUtterances() async throws {
        guard !NSScreen.screens.isEmpty else { return }
        // Anima janelas reais — exclusivo contra o harness de fluidez do
        // MainActor (ver UIHarnessLock).
        await UIHarnessLock.shared.acquire()
        defer { Task { await UIHarnessLock.shared.release() } }

        let panel = TrayInfoOverlayPanel()
        panel.prefersReducedMotion = { false }
        defer { panel.orderOut(nil) }

        let texts = [
            "",
            "hoje eu preciso ajustar",
            (1...60).map { "palavra\($0)" }.joined(separator: " "),
            "outra frase curta",
            String(repeating: "frase bem mais longa que quebra várias linhas ", count: 8),
        ]

        for cycle in 0..<3 {
            // O frame é decidido no 1º present() do ciclo (tela da âncora do
            // tray; NSScreen.main no fallback) e fica FIXO até o dismiss.
            var cycleFrame: NSRect?

            for text in texts {
                let presentation = TrayLivePreview.presentation(
                    state: .recording,
                    previewText: text,
                    enabled: true,
                    maxWidth: TrayLivePreview.defaultMaxWidth
                )
                panel.present(presentation, anchoredTo: nil)
                // Turnos de runloop para transições SwiftUI e datilografia
                // rodarem antes de medir (nada disso pode tocar o frame).
                try await Task.sleep(for: .milliseconds(200))

                if cycleFrame == nil {
                    cycleFrame = panel.frame

                    // Tamanho exato da janela fixa: área do pill + folga.
                    #expect(
                        panel.frame.height
                            == TrayInfoOverlay.pillMaxHeight + TrayInfoOverlay.windowPadding * 2
                    )

                    // Topo do PILL pregado logo abaixo da barra de menu da
                    // tela que hospeda a janela.
                    let host = NSScreen.screens.first { $0.frame.intersects(panel.frame) }
                    try #require(host != nil, "painel fora de qualquer tela: \(panel.frame)")
                    let pillTop = panel.frame.maxY - TrayInfoOverlay.windowPadding
                    let expectedTop = host!.visibleFrame.maxY - TrayInfoOverlay.topGap
                    #expect(
                        abs(pillTop - expectedTop) <= 0.5,
                        "ciclo \(cycle): topo do pill derivou \(Int(pillTop - expectedTop))pt"
                    )
                }

                #expect(
                    panel.frame == cycleFrame,
                    "ciclo \(cycle): frame mudou no meio do ditado (texto de \(text.count) chars): \(panel.frame) != \(cycleFrame!)"
                )
                #expect(panel.isVisible, "ciclo \(cycle): painel não está visível durante o ditado")
            }

            panel.dismiss()
            // Espera a transição de saída (0.16s) + orderOut agendado (240ms).
            try await Task.sleep(for: .milliseconds(400))
            #expect(!panel.isVisible, "ciclo \(cycle): painel continuou em cena após dismiss")
        }
    }

    @Test("Re-present durante a saída cancela o orderOut agendado")
    func representDuringDismissKeepsPanelOnScreen() async throws {
        guard !NSScreen.screens.isEmpty else { return }
        await UIHarnessLock.shared.acquire()
        defer { Task { await UIHarnessLock.shared.release() } }

        let panel = TrayInfoOverlayPanel()
        panel.prefersReducedMotion = { false }
        defer { panel.orderOut(nil) }

        let presentation = TrayLivePreview.presentation(
            state: .recording, previewText: "primeira fala", enabled: true, maxWidth: 220)
        panel.present(presentation, anchoredTo: nil)
        try await Task.sleep(for: .milliseconds(120))

        // Usuário para e recomeça a ditar dentro da janela de saída (240ms).
        panel.dismiss()
        try await Task.sleep(for: .milliseconds(60))
        panel.present(presentation, anchoredTo: nil)

        // Passado o prazo do orderOut da 1ª dispensa, o painel deve seguir
        // em cena (a geração invalida o orderOut antigo).
        try await Task.sleep(for: .milliseconds(400))
        #expect(panel.isVisible, "orderOut da dispensa antiga derrubou o present novo")
    }
}
