import SwiftUI

/// Design system global do zspeak.
///
/// A paleta nasce do modo tray aprovado: azul-grafite profundo, superfícies
/// frias elevadas, bordas finas e cores semânticas reservadas a estados. Todos
/// os fluxos visuais do app consomem estes tokens para não haver diferença de
/// linguagem entre janela principal, janelas auxiliares, tray e overlays.
enum ZSDesign {
    static let radius: CGFloat = 14
    static let compactRadius: CGFloat = 9
    static let pagePadding: CGFloat = 22

    static let pageBackground = Color(red: 0.022, green: 0.039, blue: 0.061)
    static let sidebarBackground = Color(red: 0.030, green: 0.052, blue: 0.078)
    static let toolbarBackground = Color(red: 0.038, green: 0.064, blue: 0.095)
    static let cardBackground = Color(red: 0.052, green: 0.086, blue: 0.130)
    static let raisedBackground = Color(red: 0.069, green: 0.108, blue: 0.156)
    static let strongBackground = Color(red: 0.078, green: 0.122, blue: 0.174)

    static let hairline = Color(red: 0.34, green: 0.43, blue: 0.54).opacity(0.66)
    static let divider = Color.white.opacity(0.13)
    static let textPrimary = Color.white.opacity(0.96)
    static let textSecondary = Color.white.opacity(0.62)
    static let textTertiary = Color.white.opacity(0.42)

    static let accent = Color(red: 0.45, green: 0.68, blue: 1.0)
    static let successAccent = Color(red: 0.33, green: 0.82, blue: 0.62)
    static let warningAccent = Color(red: 1.0, green: 0.66, blue: 0.24)
    static let dangerAccent = Color(red: 1.0, green: 0.30, blue: 0.32)
    static let infoAccent = Color(red: 0.35, green: 0.78, blue: 0.93)
    static let neutralAccent = Color(red: 0.58, green: 0.65, blue: 0.74)

    static let cardShadow = Color.black.opacity(0.24)
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
        case .accent: return ZSDesign.accent
        case .success: return ZSDesign.successAccent
        case .warning: return ZSDesign.warningAccent
        case .danger: return ZSDesign.dangerAccent
        case .neutral: return ZSDesign.neutralAccent
        case .info: return ZSDesign.infoAccent
        }
    }
}

/// Chrome compartilhado por páginas com `Form`, `List` ou `ScrollView`.
/// Mantém o app deliberadamente escuro mesmo quando o macOS usa modo claro.
private struct ZSAppSurfaceModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(ZSDesign.pageBackground.ignoresSafeArea())
            .foregroundStyle(ZSDesign.textPrimary)
            .tint(ZSDesign.accent)
            .preferredColorScheme(.dark)
    }
}

extension View {
    func zsAppSurface() -> some View {
        modifier(ZSAppSurfaceModifier())
    }
}

/// Símbolo semântico sobre uma superfície fria e discreta. A cor identifica o
/// estado sem competir com o conteúdo, como no indicador "AO VIVO" do tray.
struct ZSSettingsIcon: View {
    let systemImage: String
    let color: Color
    var size: CGFloat = 22

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(color.opacity(0.17))
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: systemImage)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(color)
            )
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .strokeBorder(color.opacity(0.42), lineWidth: 0.7)
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
                    .foregroundStyle(ZSDesign.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(ZSDesign.textSecondary)
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
                    .foregroundStyle(ZSDesign.textPrimary)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(ZSDesign.textSecondary)
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
                .fill(ZSDesign.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ZSDesign.radius, style: .continuous)
                .strokeBorder(tone.color.opacity(0.52), lineWidth: 0.8)
        )
        .shadow(color: ZSDesign.cardShadow, radius: 10, y: 4)
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
                    .foregroundStyle(ZSDesign.textPrimary)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(ZSDesign.textSecondary)
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
        .shadow(color: ZSDesign.cardShadow, radius: 8, y: 3)
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
        .background(ZSDesign.raisedBackground, in: Capsule())
        .overlay(Capsule().strokeBorder(tone.color.opacity(0.38), lineWidth: 0.7))
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
                    .foregroundStyle(ZSDesign.textSecondary)
            }

            Text(value)
                .font(.title3.weight(.semibold))
                .foregroundStyle(ZSDesign.textPrimary)
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
        .shadow(color: ZSDesign.cardShadow, radius: 7, y: 3)
    }
}
