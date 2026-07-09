import AppKit
import Foundation
import Testing
@testable import zspeak

@Suite("TrayInfoOverlay")
struct TrayInfoOverlayTests {

    @Test("Visível só no ciclo de ditado do modo tray, sem Modo Prompt")
    func visibilityGating() {
        #expect(TrayInfoOverlay.isVisible(state: .preparing, trayModeEnabled: true, promptModeActive: false))
        #expect(TrayInfoOverlay.isVisible(state: .recording, trayModeEnabled: true, promptModeActive: false))
        #expect(TrayInfoOverlay.isVisible(state: .processing, trayModeEnabled: true, promptModeActive: false))

        #expect(!TrayInfoOverlay.isVisible(state: .idle, trayModeEnabled: true, promptModeActive: false))
        #expect(!TrayInfoOverlay.isVisible(state: .recording, trayModeEnabled: false, promptModeActive: false))
        // Modo Prompt: o overlay grande está em cena — mini-overlay duplicaria.
        #expect(!TrayInfoOverlay.isVisible(state: .recording, trayModeEnabled: true, promptModeActive: true))
    }

    @Test("Modo tray suprime o overlay grande durante o ditado")
    func mainOverlaySuppression() {
        #expect(TrayInfoOverlay.suppressesMainOverlay(state: .preparing, trayModeEnabled: true))
        #expect(TrayInfoOverlay.suppressesMainOverlay(state: .recording, trayModeEnabled: true))
        #expect(TrayInfoOverlay.suppressesMainOverlay(state: .processing, trayModeEnabled: true))

        #expect(!TrayInfoOverlay.suppressesMainOverlay(state: .recording, trayModeEnabled: false))
        #expect(!TrayInfoOverlay.suppressesMainOverlay(state: .idle, trayModeEnabled: true))
    }

    @Test("Texto curto aparece inteiro; excedente mantém a cauda em fronteira de palavra")
    func tailText() {
        #expect(TrayInfoOverlay.displayTailText("frase curta") == "frase curta")

        let words = (1...200).map { "palavra\($0)" }
        let long = words.joined(separator: " ")
        let display = TrayInfoOverlay.displayTailText(long)

        #expect(display.hasPrefix("…"))
        // As palavras mais novas (fim do ditado) permanecem visíveis.
        #expect(display.hasSuffix("palavra200"))
        #expect(display.count <= TrayInfoOverlay.maxDisplayCharacters + 1)
        // Corte alinhado em palavra: o primeiro token após a reticência é uma
        // palavra completa do texto original, nunca um pedaço.
        let firstToken = display.dropFirst().split(separator: " ").first.map(String.init)
        #expect(firstToken.map { words.contains($0) } == true)
    }

    @Test("Palavra única gigante não vira texto vazio")
    func tailTextDegenerateWord() {
        let giant = String(repeating: "a", count: 700)
        let display = TrayInfoOverlay.displayTailText(giant)
        #expect(display.hasPrefix("…"))
        #expect(display.count == TrayInfoOverlay.maxDisplayCharacters + 1)
    }

    @Test("Origem: sob a barra de menu, borda direita alinhada ao item do tray, clampado à tela")
    func originPlacement() {
        // visibleFrame já exclui a barra de menu — maxY é a base da barra.
        let visible = NSRect(x: 0, y: 0, width: 1512, height: 950)
        let size = NSSize(width: 460, height: 40)

        let item = NSRect(x: 1200, y: 950, width: 220, height: 24)
        let anchored = TrayInfoOverlay.origin(panelSize: size, statusItemFrame: item, screenVisibleFrame: visible)
        #expect(anchored.x == item.maxX - size.width)
        #expect(anchored.y == visible.maxY - TrayInfoOverlay.topGap - size.height)

        // Item colado à esquerda: clampa na margem esquerda da tela.
        let leftItem = NSRect(x: 4, y: 950, width: 42, height: 24)
        let clamped = TrayInfoOverlay.origin(panelSize: size, statusItemFrame: leftItem, screenVisibleFrame: visible)
        #expect(clamped.x == visible.minX + TrayInfoOverlay.edgeMargin)

        // Sem âncora (item oculto pela barra cheia): canto direito da tela.
        let free = TrayInfoOverlay.origin(panelSize: size, statusItemFrame: nil, screenVisibleFrame: visible)
        #expect(free.x == visible.maxX - TrayInfoOverlay.edgeMargin - size.width)
    }

    @Test("Largura: default e piso")
    func widthDefaults() {
        let suiteName = "tray-info-overlay-tests"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        #expect(TrayInfoOverlay.width(defaults: defaults) == TrayInfoOverlay.defaultWidth)

        defaults.set(300.0, forKey: TrayInfoOverlay.widthDefaultsKey)
        #expect(TrayInfoOverlay.width(defaults: defaults) == 300)

        defaults.set(100.0, forKey: TrayInfoOverlay.widthDefaultsKey)
        #expect(TrayInfoOverlay.width(defaults: defaults) == TrayInfoOverlay.minimumWidth)

        defaults.removePersistentDomain(forName: suiteName)
    }
}
