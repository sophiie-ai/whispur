import SwiftUI

struct PreferenceCard<Content: View>: View {
    let title: String
    let detail: String?
    let icon: String
    let content: Content

    init(
        _ title: String,
        detail: String? = nil,
        icon: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.detail = detail
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(SophiieTheme.Palette.ink)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(SophiieTheme.Typography.heading)
                        .foregroundStyle(SophiieTheme.Palette.ink)

                    if let detail {
                        Text(detail)
                            .font(.subheadline)
                            .foregroundStyle(SophiieTheme.Palette.muted)
                    }
                }
            }

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sophiieCard(padding: 18, radius: SophiieTheme.Radius.panel)
    }
}

struct PreferenceBadge: View {
    let title: String
    let tone: Tone

    @Environment(\.colorScheme) private var colorScheme

    enum Tone: Equatable {
        case neutral
        case good
        case warning
        case critical

        var color: Color {
            switch self {
            case .neutral:
                return SophiieTheme.Palette.muted
            case .good:
                return SophiieTheme.Palette.success
            case .warning:
                return SophiieTheme.Palette.warning
            case .critical:
                return SophiieTheme.Palette.danger
            }
        }
    }

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(tone.color.opacity(fillOpacity), in: Capsule())
            .foregroundStyle(tone.color)
    }

    /// A lighter tint in light mode keeps the status text at 4.5:1 or
    /// better against the pill on the window canvas.
    private var fillOpacity: Double {
        colorScheme == .dark ? 0.14 : 0.08
    }
}

struct ShortcutSummaryBadge: View {
    let title: String

    var body: some View {
        Text(title)
            .font(SophiieTheme.Typography.captionStrong)
            .foregroundStyle(SophiieTheme.Palette.ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(SophiieTheme.Palette.surfaceSubtle, in: Capsule())
    }
}

struct SetupChecklistRow: View {
    let title: String
    let detail: String
    let isComplete: Bool
    let actionTitle: String?
    let action: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: isComplete ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(isComplete ? SophiieTheme.Palette.success : SophiieTheme.Palette.warning)
                .font(.title3)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(SophiieTheme.Palette.ink)

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(SophiieTheme.Palette.muted)
            }

            Spacer(minLength: 8)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.sophiieSecondary)
                    .controlSize(.small)
            }
        }
        .sophiieWell(padding: 14, radius: SophiieTheme.Radius.card)
    }
}

struct DetailRow<Accessory: View>: View {
    let title: String
    let detail: String?
    let accessory: Accessory

    init(
        _ title: String,
        detail: String? = nil,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.title = title
        self.detail = detail
        self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(SophiieTheme.Typography.label)
                    .foregroundStyle(SophiieTheme.Palette.ink)

                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(SophiieTheme.Palette.muted)
                }
            }

            Spacer(minLength: 8)

            accessory
        }
        .padding(.vertical, 2)
    }
}
