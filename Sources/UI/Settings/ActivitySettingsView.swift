import SwiftUI

/// Activity: the saved dictations, newest first, each expandable to the
/// cleaned and raw transcript.
struct ActivitySettingsView: View {
    @ObservedObject var historyStore: PipelineHistoryStore

    var body: some View {
        SettingsPage {
            PageHeader(
                SettingsTab.activity.title,
                pill: historyStore.items.isEmpty ? nil : "\(historyStore.items.count) saved",
                subtitle: SettingsTab.activity.summary
            ) {
                if !historyStore.items.isEmpty {
                    Button("Clear History") { historyStore.clear() }
                        .buttonStyle(.sophiieSecondary)
                }
            }

            if historyStore.items.isEmpty {
                SettingsCard {
                    SettingsRow(
                        icon: "waveform.slash",
                        title: "No activity yet",
                        subtitle: "Run a dictation and Whispur keeps the recent cleaned and raw transcripts here."
                    )
                }
            } else {
                SettingsSection("Recent dictations", footer: "Whispur keeps your most recent dictations on this Mac.") {
                    SettingsCard {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(historyStore.items.enumerated()), id: \.element.id) { index, item in
                                if index > 0 { CardDivider(leadingInset: 0) }
                                ActivityEntry(item: item)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct ActivityEntry: View {
    let item: PipelineResult

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withSophiieAnimation { isExpanded.toggle() }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.cleanedText)
                            .font(.system(size: 13))
                            .foregroundStyle(SophiieTheme.Palette.ink)
                            .lineLimit(isExpanded ? nil : 2)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(item.timestamp.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 11.5))
                            .foregroundStyle(SophiieTheme.Palette.muted)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(SophiieTheme.Palette.muted)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    transcriptBlock("Cleaned", item.cleanedText)
                    transcriptBlock("Raw", item.rawTranscript)
                    HStack(spacing: 8) {
                        PreferenceBadge(title: item.sttProvider.displayName, tone: .neutral)
                        PreferenceBadge(title: item.llmProvider.displayName, tone: .neutral)
                        if let llmModel = item.llmModel {
                            PreferenceBadge(title: llmModel, tone: .neutral)
                        }
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(.vertical, 12)
    }

    private func transcriptBlock(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(SophiieTheme.Typography.captionStrong)
                .foregroundStyle(SophiieTheme.Palette.muted)
            Text(text)
                .font(SophiieTheme.Typography.mono)
                .foregroundStyle(SophiieTheme.Palette.inkSecondary)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(SophiieTheme.Palette.surfaceSubtle, in: RoundedRectangle(cornerRadius: SophiieTheme.Radius.small, style: .continuous))
        }
    }
}
