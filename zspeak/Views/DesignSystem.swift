import SwiftUI

/// Primitivos visuais compartilhados entre Settings, janelas auxiliares e
/// estados ricos. Mantém a UI consistente sem criar dependência externa.
enum ZSDesign {
    static let radius: CGFloat = 8
    static let compactRadius: CGFloat = 6
    static let pagePadding: CGFloat = 20

    static var pageBackground: LinearGradient {
        LinearGradient(
            colors: [
                Color(nsColor: .windowBackgroundColor),
                Color(nsColor: .controlBackgroundColor).opacity(0.72),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static var cardBackground: Color {
        Color(nsColor: .controlBackgroundColor)
    }

    static var raisedBackground: Color {
        Color(nsColor: .textBackgroundColor)
    }

    static var hairline: Color {
        Color.primary.opacity(0.10)
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
        case .neutral: return .secondary
        case .info: return .blue
        }
    }
}

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

            VStack(alignment: .leading, spacing: 4) {
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
        .padding(16)
        .background(ZSDesign.cardBackground, in: RoundedRectangle(cornerRadius: ZSDesign.radius))
        .overlay(
            RoundedRectangle(cornerRadius: ZSDesign.radius)
                .strokeBorder(ZSDesign.hairline)
        )
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

struct ZSSectionCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
        }
        .padding(16)
        .background(ZSDesign.cardBackground, in: RoundedRectangle(cornerRadius: ZSDesign.radius))
        .overlay(
            RoundedRectangle(cornerRadius: ZSDesign.radius)
                .strokeBorder(ZSDesign.hairline)
        )
    }
}

struct ZSFormHero: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tone: ZSTone

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ZSIconBadge(systemImage: systemImage, tone: tone)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}

struct ZSIconBadge: View {
    let systemImage: String
    let tone: ZSTone

    var body: some View {
        Image(systemName: systemImage)
            .font(.title3.weight(.semibold))
            .foregroundStyle(tone.color)
            .frame(width: 36, height: 36)
            .background(tone.color.opacity(0.13), in: RoundedRectangle(cornerRadius: ZSDesign.compactRadius))
            .accessibilityHidden(true)
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

struct ZSMetricTile: View {
    let title: String
    let value: String
    let systemImage: String
    let tone: ZSTone

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .foregroundStyle(tone.color)
                    .accessibilityHidden(true)
                Text(title)
                    .foregroundStyle(.secondary)
            }
            .font(.caption.weight(.medium))

            Text(value)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(ZSDesign.raisedBackground, in: RoundedRectangle(cornerRadius: ZSDesign.compactRadius))
        .overlay(
            RoundedRectangle(cornerRadius: ZSDesign.compactRadius)
                .strokeBorder(ZSDesign.hairline)
        )
    }
}

private struct ZSFormPageModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(ZSDesign.pageBackground)
    }
}

extension View {
    func zsFormPage() -> some View {
        modifier(ZSFormPageModifier())
    }
}
