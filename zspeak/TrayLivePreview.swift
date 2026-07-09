import AppKit
import Foundation

/// Apresentação do item do tray (barra de menu) para o "modo compacto":
/// enquanto grava/transcreve, o item expande para uma largura MÁXIMA FIXA e
/// mostra a cauda da transcrição ao vivo (truncada pela cabeça — as palavras
/// mais novas ficam sempre visíveis); fora do ciclo volta ao selo "ZS".
struct TrayPreviewPresentation: Equatable {
    /// Largura do NSStatusItem (fixa por estado — a barra de menu não fica
    /// "pulando" a cada palavra transcrita).
    var length: CGFloat
    /// Texto do botão (linha única; truncado pela cabeça via lineBreakMode).
    var text: String
    /// Símbolo SF à esquerda do texto (nil = sem imagem).
    var symbolName: String?
    /// Pinta o símbolo de vermelho (dot de gravação); false = template.
    var isRecordingDot: Bool
    /// true quando está exibindo preview ao vivo (fonte menor, alinhado à
    /// esquerda); false para o selo compacto "ZS".
    var isLivePreview: Bool
    /// true quando o texto é placeholder ("Ouvindo…") — renderiza em cor
    /// secundária para diferenciar da transcrição real.
    var isPlaceholderText: Bool
}

enum TrayLivePreview {
    /// Tunáveis sem rebuild:
    /// `defaults write com.zspeak.app trayLivePreviewEnabled -bool NO`
    /// `defaults write com.zspeak.app trayLivePreviewMaxWidth -float 280`
    static let enabledDefaultsKey = "trayLivePreviewEnabled"
    static let maxWidthDefaultsKey = "trayLivePreviewMaxWidth"

    static let idleLength: CGFloat = 42
    /// Selo compacto com indicador de estado (dot/waveform + "ZS").
    static let compactBadgeLength: CGFloat = 54
    static let defaultMaxWidth: CGFloat = 220
    /// Piso para valores customizados — abaixo disso nem o placeholder cabe.
    static let minimumMaxWidth: CGFloat = 120

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: enabledDefaultsKey) != nil else { return true }
        return defaults.bool(forKey: enabledDefaultsKey)
    }

    static func maxWidth(defaults: UserDefaults = .standard) -> CGFloat {
        let raw = defaults.double(forKey: maxWidthDefaultsKey)
        guard raw > 0 else { return defaultMaxWidth }
        return max(minimumMaxWidth, CGFloat(raw))
    }

    /// Colapsa o preview em linha única com espaçamento normalizado — o tray
    /// não comporta quebras nem runs de espaço.
    static func sanitizedSingleLine(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Selo COMPACTO com indicador de estado — usado quando o mini-overlay
    /// (TrayInfoOverlay) já está mostrando o texto logo abaixo da barra: o
    /// item do tray não duplica o conteúdo, só sinaliza o estado ao lado do
    /// "ZS" (dot vermelho gravando; waveform processando).
    static func compactBadge(state: AppState.RecordingState) -> TrayPreviewPresentation {
        let symbolName: String?
        let isRecordingDot: Bool
        switch state {
        case .idle:
            symbolName = nil
            isRecordingDot = false
        case .preparing:
            symbolName = "record.circle"
            isRecordingDot = true
        case .recording:
            symbolName = "record.circle.fill"
            isRecordingDot = true
        case .processing:
            symbolName = "waveform"
            isRecordingDot = false
        }
        return TrayPreviewPresentation(
            length: symbolName == nil ? idleLength : compactBadgeLength,
            text: "ZS",
            symbolName: symbolName,
            isRecordingDot: isRecordingDot,
            isLivePreview: false,
            isPlaceholderText: false
        )
    }

    static func presentation(
        state: AppState.RecordingState,
        previewText: String,
        enabled: Bool,
        maxWidth: CGFloat
    ) -> TrayPreviewPresentation {
        let idle = TrayPreviewPresentation(
            length: idleLength,
            text: "ZS",
            symbolName: nil,
            isRecordingDot: false,
            isLivePreview: false,
            isPlaceholderText: false
        )
        guard enabled else { return idle }

        let text = sanitizedSingleLine(previewText)
        switch state {
        case .idle:
            return idle
        case .preparing:
            return TrayPreviewPresentation(
                length: maxWidth,
                text: "Preparando…",
                symbolName: "record.circle",
                isRecordingDot: true,
                isLivePreview: true,
                isPlaceholderText: true
            )
        case .recording:
            return TrayPreviewPresentation(
                length: maxWidth,
                text: text.isEmpty ? "Ouvindo…" : text,
                symbolName: "record.circle.fill",
                isRecordingDot: true,
                isLivePreview: true,
                isPlaceholderText: text.isEmpty
            )
        case .processing:
            return TrayPreviewPresentation(
                length: maxWidth,
                text: text.isEmpty ? "Transcrevendo…" : text,
                symbolName: "waveform",
                isRecordingDot: false,
                isLivePreview: true,
                isPlaceholderText: text.isEmpty
            )
        }
    }

    /// Aplica a apresentação no NSStatusItem (largura + visual do botão).
    @MainActor
    static func apply(_ presentation: TrayPreviewPresentation, to statusItem: NSStatusItem) {
        guard let button = statusItem.button else { return }

        if abs(statusItem.length - presentation.length) > 0.5 {
            statusItem.length = presentation.length
        }
        configure(button: button, with: presentation)
    }

    /// Visual do botão — compartilhado entre o item real e o harness visual
    /// (o NSStatusBarButton desenha o título com vibrancy, que não sobrevive
    /// a capturas offscreen; o harness usa um NSButton comum com ESTA mesma
    /// configuração para inspecionar tipografia/espaçamento/truncamento).
    @MainActor
    static func configure(button: NSButton, with presentation: TrayPreviewPresentation) {
        // Truncamento pela CABEÇA: em texto ao vivo, o fim (palavras novas)
        // é o que importa — "…do serviço de transcrição".
        button.lineBreakMode = .byTruncatingHead

        let font: NSFont
        if presentation.isLivePreview {
            font = NSFont.systemFont(ofSize: 12)
            button.alignment = .left
        } else {
            font = NSFont.menuBarFont(ofSize: 0)
            button.alignment = .center
        }
        button.font = font

        if presentation.isPlaceholderText {
            // Placeholder em cor secundária — diferencia "esperando fala" da
            // transcrição real (que usa a cor vibrante padrão do tray).
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingHead
            paragraph.alignment = .left
            button.attributedTitle = NSAttributedString(
                string: presentation.text,
                attributes: [
                    .font: font,
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .paragraphStyle: paragraph,
                ]
            )
        } else {
            button.title = presentation.text
        }

        if let symbolName = presentation.symbolName {
            let base = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
            if presentation.isRecordingDot {
                let config = NSImage.SymbolConfiguration(pointSize: 9.5, weight: .bold)
                    .applying(.init(paletteColors: [.systemRed]))
                let tinted = base?.withSymbolConfiguration(config)
                tinted?.isTemplate = false
                button.image = tinted
            } else {
                button.image = base?.withSymbolConfiguration(
                    .init(pointSize: 10, weight: .semibold)
                )
            }
            button.imagePosition = .imageLeading
        } else {
            button.image = nil
            button.imagePosition = .noImage
        }
    }
}
