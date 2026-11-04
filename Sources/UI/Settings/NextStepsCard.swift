import SwiftUI

/// The "Next steps" card at the top of the Dictation page. What shows and
/// what is done comes from `NextSteps`; this view only draws it.
struct NextStepsCard: View {
    let display: NextSteps.Display
    /// How to start talking, with the user's own shortcut.
    let talkHint: String
    let openTab: (SettingsTab) -> Void
    let onDismiss: () -> Void

    /// How long "All set" stays before the card goes away for good.
    static let allSetBeat: Duration = .seconds(4)

    var body: some View {
        switch display {
        case .hidden:
            EmptyView()
        case let .steps(items, done):
            stepsCard(items, done: done)
        case .allSet:
            allSetCard
        }
    }

    private func stepsCard(_ items: [NextSteps.Item], done: Set<NextSteps.Item>) -> some View {
        SettingsCard {
            CardContent {
                HStack(alignment: .firstTextBaseline) {
                    Text("Next steps")
                        .font(.system(size: 15, weight: .semibold))
                        .tracking(SophiieTheme.Typography.titleTracking)
                        .foregroundStyle(SophiieTheme.Palette.ink)
                    Text(Self.progressLabel(done: done.count, of: items.count))
                        .font(.system(size: 12))
                        .foregroundStyle(SophiieTheme.Palette.muted)
                    Spacer()
                    InlineIconButton(systemName: "xmark", label: "Hide next steps", action: onDismiss)
                }
            }
            ForEach(items) { item in
                CardDivider()
                row(item, isDone: done.contains(item))
            }
            CardDivider(leadingInset: 0)
            Label("Whispur lives in your menu bar. Close this window any time.", systemImage: "menubar.rectangle")
                .font(SophiieTheme.Typography.caption)
                .foregroundStyle(SophiieTheme.Palette.muted)
                .padding(.vertical, 12)
        }
    }

    @ViewBuilder
    private func row(_ item: NextSteps.Item, isDone: Bool) -> some View {
        let content = SettingsRow(
            icon: isDone ? "checkmark.circle.fill" : "circle.dashed",
            title: Self.title(for: item),
            subtitle: isDone ? "Done" : subtitle(for: item),
            iconTint: isDone ? SophiieTheme.Palette.success : SophiieTheme.Palette.interactive
        ) {
            if item.tab != nil { ChevronAccessory() }
        }
        Group {
            if let tab = item.tab {
                Button { openTab(tab) } label: { content.contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(.isButton)
            } else {
                content
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(isDone ? "Done" : "Not done")
    }

    private var allSetCard: some View {
        SettingsCard {
            SettingsRow(
                icon: "checkmark.seal.fill",
                title: "All set",
                subtitle: "You know the basics. Enjoy talking instead of typing.",
                iconTint: SophiieTheme.Palette.success
            ) {
                InlineIconButton(systemName: "xmark", label: "Hide next steps", action: onDismiss)
            }
        }
        .task {
            try? await Task.sleep(for: Self.allSetBeat)
            guard !Task.isCancelled else { return }
            withSophiieAnimation { onDismiss() }
        }
    }

    static func progressLabel(done: Int, of total: Int) -> String {
        "\(done) of \(total) done"
    }

    static func title(for item: NextSteps.Item) -> String {
        switch item {
        case .dictate: return "Dictate in another app"
        case .dictionary: return "Add a word to your dictionary"
        case .style: return "Pick a writing style"
        case .cleanupKey: return "Add a cleanup key (optional)"
        }
    }

    private func subtitle(for item: NextSteps.Item) -> String {
        switch item {
        case .dictate: return talkHint
        case .dictionary: return "Names and terms Whispur should spell your way"
        case .style: return "Choose how cleanup reads in each app"
        case .cleanupKey: return "Lets AI fix punctuation and drop filler words"
        }
    }
}
