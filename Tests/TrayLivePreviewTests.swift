import Foundation
import Testing
@testable import zspeak

@Suite("TrayLivePreview")
struct TrayLivePreviewTests {

    @Test("Idle e desabilitado voltam ao selo compacto ZS")
    func idleAndDisabledCollapse() {
        let idle = TrayLivePreview.presentation(
            state: .idle, previewText: "sobra de texto", enabled: true, maxWidth: 220)
        let disabled = TrayLivePreview.presentation(
            state: .recording, previewText: "gravando algo", enabled: false, maxWidth: 220)

        for presentation in [idle, disabled] {
            #expect(presentation.length == TrayLivePreview.idleLength)
            #expect(presentation.text == "ZS")
            #expect(presentation.symbolName == nil)
            #expect(!presentation.isLivePreview)
        }
    }

    @Test("Gravando mostra a transcrição ao vivo com largura máxima fixa e dot vermelho")
    func recordingShowsLiveText() {
        let empty = TrayLivePreview.presentation(
            state: .recording, previewText: "", enabled: true, maxWidth: 220)
        let withText = TrayLivePreview.presentation(
            state: .recording, previewText: "hoje eu preciso ajustar", enabled: true, maxWidth: 220)

        #expect(empty.text == "Ouvindo…")
        #expect(empty.isPlaceholderText)
        #expect(withText.text == "hoje eu preciso ajustar")
        #expect(!withText.isPlaceholderText)
        for presentation in [empty, withText] {
            #expect(presentation.length == 220)
            #expect(presentation.isRecordingDot)
            #expect(presentation.isLivePreview)
        }
    }

    @Test("Largura é FIXA no máximo — não varia com o tamanho do texto")
    func widthStaysFixedRegardlessOfText() {
        let short = TrayLivePreview.presentation(
            state: .recording, previewText: "oi", enabled: true, maxWidth: 240)
        let long = TrayLivePreview.presentation(
            state: .recording,
            previewText: String(repeating: "palavra ", count: 80),
            enabled: true,
            maxWidth: 240
        )

        #expect(short.length == 240)
        #expect(long.length == 240)
    }

    @Test("Processing mantém o texto e troca o dot por símbolo template")
    func processingKeepsText() {
        let presentation = TrayLivePreview.presentation(
            state: .processing, previewText: "frase final dita", enabled: true, maxWidth: 220)
        let withoutText = TrayLivePreview.presentation(
            state: .processing, previewText: "  ", enabled: true, maxWidth: 220)

        #expect(presentation.text == "frase final dita")
        #expect(!presentation.isRecordingDot)
        #expect(presentation.symbolName == "waveform")
        #expect(withoutText.text == "Transcrevendo…")
        #expect(withoutText.isPlaceholderText)
    }

    @Test("Selo compacto: com o mini-overlay em cena o item não expande nem duplica texto")
    func compactBadgeKeepsItemSmall() {
        let recording = TrayLivePreview.compactBadge(state: .recording)
        #expect(recording.length == TrayLivePreview.compactBadgeLength)
        #expect(recording.text == "ZS")
        #expect(recording.symbolName == "circle.fill")
        #expect(recording.isRecordingDot)
        #expect(!recording.isLivePreview)
        #expect(recording.state == .recording)

        let preparing = TrayLivePreview.compactBadge(state: .preparing)
        #expect(preparing.isRecordingDot)
        #expect(preparing.length == TrayLivePreview.compactBadgeLength)

        let processing = TrayLivePreview.compactBadge(state: .processing)
        #expect(processing.symbolName == "waveform")
        #expect(!processing.isRecordingDot)
        #expect(processing.state == .processing)

        let idle = TrayLivePreview.compactBadge(state: .idle)
        #expect(idle.length == TrayLivePreview.idleLength)
        #expect(idle.symbolName == nil)
    }

    @Test("Preview vira linha única sem quebras")
    func sanitizesNewlines() {
        #expect(TrayLivePreview.sanitizedSingleLine("linha um\nlinha dois\r\n  fim  ") == "linha um linha dois fim")

        let presentation = TrayLivePreview.presentation(
            state: .recording, previewText: "um\ndois", enabled: true, maxWidth: 220)
        #expect(presentation.text == "um dois")
    }

    @Test("Item do tray expõe estado textual para VoiceOver")
    func accessibilityLabels() {
        #expect(TrayLivePreview.accessibilityLabel(for: .idle) == "zspeak, pronto")
        #expect(TrayLivePreview.accessibilityLabel(for: .recording) == "zspeak, gravando áudio")
        #expect(TrayLivePreview.accessibilityLabel(for: .processing) == "zspeak, transcrevendo")
    }

    @Test("Defaults: habilitado por padrão, largura com default e piso")
    func defaultsGates() {
        let defaults = UserDefaults(suiteName: "tray-live-preview-tests")!
        defaults.removePersistentDomain(forName: "tray-live-preview-tests")

        #expect(TrayLivePreview.isEnabled(defaults: defaults))
        #expect(TrayLivePreview.maxWidth(defaults: defaults) == TrayLivePreview.defaultMaxWidth)

        defaults.set(false, forKey: TrayLivePreview.enabledDefaultsKey)
        #expect(!TrayLivePreview.isEnabled(defaults: defaults))

        defaults.set(300.0, forKey: TrayLivePreview.maxWidthDefaultsKey)
        #expect(TrayLivePreview.maxWidth(defaults: defaults) == 300)

        // Valor absurdo cai no piso — nem o placeholder caberia abaixo dele.
        defaults.set(40.0, forKey: TrayLivePreview.maxWidthDefaultsKey)
        #expect(TrayLivePreview.maxWidth(defaults: defaults) == TrayLivePreview.minimumMaxWidth)

        defaults.removePersistentDomain(forName: "tray-live-preview-tests")
    }
}
