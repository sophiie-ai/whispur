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
                    .foregroundStyle(.orange)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)

                    if let detail {
                        Text(detail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}

struct PreferenceBadge: View {
    let title: String
    let tone: Tone

    enum Tone: Equatable {
        case neutral
        case good
        case warning
        case critical

        var color: Color {
            switch self {
            case .neutral:
                return .secondary
            case .good:
                return .green
            case .warning:
                return .orange
            case .critical:
                return .red
            }
        }
    }

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(tone.color.opacity(0.12), in: Capsule())
            .foregroundStyle(tone.color)
    }
}

struct ShortcutSummaryBadge: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(.caption, design: .rounded).weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.06), in: Capsule())
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
                .foregroundStyle(isComplete ? .green : .orange)
                .font(.title3)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(14)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
                    .font(.subheadline.weight(.medium))

                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            accessory
        }
        .padding(.vertical, 2)
    }
}
