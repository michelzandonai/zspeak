import SwiftUI

/// Primitivos visuais compartilhados entre Settings, janelas auxiliares e
/// estados ricos. A linguagem segue os Ajustes do Sistema do macOS: forms
/// agrupados nativos, ícones brancos sobre squircle com gradiente e ênfase
/// por tint suave — nunca bordas pesadas nem fundos customizados.
enum ZSDesign {
    static let radius: CGFloat = 10
    static let compactRadius: CGFloat = 7
    static let pagePadding: CGFloat = 20

    /// Fundo de janelas que não usam Form agrupado (ex.: Transcrever Arquivo).
    static var pageBackground: Color {
        Color(nsColor: .windowBackgroundColor)
    }

    static var cardBackground: Color {
        Color(nsColor: .controlBackgroundColor)
    }

    static var raisedBackground: Color {
        Color(nsColor: .textBackgroundColor)
    }

    /// Contorno sutil de cards: dá definição no modo claro sem virar "caixa".
    static var hairline: Color {
        Color.primary.opacity(0.06)
    }
}

enum ZSTone {
    case accent
    case success
    case warning
    case danger
    case neutral
    case info

    var color: Color {
        switch self {
        case .accent: return .accentColor
        case .success: return .green
        case .warning: return .orange
        case .danger: return .red
        case .neutral: return .gray
        case .info: return .blue
        }
    }
}

/// Ícone no estilo dos Ajustes do Sistema: símbolo branco centrado num
/// squircle preenchido com gradiente da cor. Usado na sidebar, em rows de
/// status e em banners.
struct ZSSettingsIcon: View {
    let systemImage: String
    let color: Color
    var size: CGFloat = 22

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(color.gradient)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: systemImage)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .accessibilityHidden(true)
    }
}

/// Label de row de formulário com ícone squircle à esquerda — o padrão de
/// toda row nos Ajustes do Sistema. Usar como label de Toggle/Picker ou
/// direto em rows customizadas.
struct ZSRowLabel: View {
    let title: String
    let systemImage: String
    let color: Color
    var subtitle: String?

    init(_ title: String, systemImage: String, color: Color, subtitle: String? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.color = color
        self.subtitle = subtitle
    }

    var body: some View {
        HStack(spacing: 10) {
            ZSSettingsIcon(systemImage: systemImage, color: color, size: 24)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 1)
    }
}

/// Badge de ícone maior para cards e headers — mesma linguagem do
/// `ZSSettingsIcon`, dimensão fixa de destaque.
struct ZSIconBadge: View {
    let systemImage: String
    let tone: ZSTone

    var body: some View {
        ZSSettingsIcon(systemImage: systemImage, color: tone.color, size: 36)
    }
}

/// Banner de status no topo de páginas de diagnóstico (Visão Geral,
/// Permissões). Tint suave da cor do tom em vez de card cinza com borda.
struct ZSStatusBanner: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tone: ZSTone
    var chipText: String?

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            ZSSettingsIcon(systemImage: systemImage, color: tone.color, size: 40)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            if let chipText {
                ZSStatusChip(text: chipText, tone: tone)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: ZSDesign.radius, style: .continuous)
                .fill(tone.color.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: ZSDesign.radius, style: .continuous)
                .strokeBorder(tone.color.opacity(0.16))
        )
    }
}

/// Header de página para janelas fora do Settings (ex.: Transcrever Arquivo).
struct ZSPageHeader<Accessory: View>: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tone: ZSTone
    @ViewBuilder let accessory: Accessory

    init(
        title: String,
        subtitle: String,
        systemImage: String,
        tone: ZSTone = .accent,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.tone = tone
        self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            ZSIconBadge(systemImage: systemImage, tone: tone)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)
            accessory
        }
        .padding(.vertical, 6)
    }
}

extension ZSPageHeader where Accessory == EmptyView {
    init(
        title: String,
        subtitle: String,
        systemImage: String,
        tone: ZSTone = .accent
    ) {
        self.init(title: title, subtitle: subtitle, systemImage: systemImage, tone: tone) {
            EmptyView()
        }
    }
}

/// Card de seção para janelas fora do Settings. Fundo elevado, canto
/// contínuo e hairline sutil — sem a moldura dura antiga.
struct ZSSectionCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZSDesign.cardBackground,
            in: RoundedRectangle(cornerRadius: ZSDesign.radius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ZSDesign.radius, style: .continuous)
                .strokeBorder(ZSDesign.hairline)
        )
    }
}

struct ZSStatusChip: View {
    let text: String
    let tone: ZSTone
    var systemImage: String?

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption2.weight(.semibold))
                    .accessibilityHidden(true)
            }
            Text(text)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(tone.color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tone.color.opacity(0.12), in: Capsule())
    }
}

/// Tile de métrica compacta (grids da Visão Geral, Histórico e Benchmark).
struct ZSMetricTile: View {
    let title: String
    let value: String
    let systemImage: String
    let color: Color

    init(title: String, value: String, systemImage: String, tone: ZSTone) {
        self.init(title: title, value: value, systemImage: systemImage, color: tone.color)
    }

    init(title: String, value: String, systemImage: String, color: Color) {
        self.title = title
        self.value = value
        self.systemImage = systemImage
        self.color = color
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                ZSSettingsIcon(systemImage: systemImage, color: color, size: 20)
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            Text(value)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            ZSDesign.cardBackground,
            in: RoundedRectangle(cornerRadius: ZSDesign.radius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ZSDesign.radius, style: .continuous)
                .strokeBorder(ZSDesign.hairline)
        )
    }
}
