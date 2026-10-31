import SwiftUI

/// Pipeline history / debug log.
struct RunLogView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                headerCard

                if appState.historyStore.items.isEmpty {
                    PreferenceCard(
                        "No Activity Yet",
                        detail: "Run a dictation and Whispur will keep the recent cleaned and raw transcripts here.",
                        icon: "waveform.slash"
                    ) {
                        Text("Your first successful dictation will appear in this timeline.")
                            .font(.subheadline)
                            .foregroundStyle(SophiieTheme.Palette.muted)
                    }
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(appState.historyStore.items) { item in
                            RunLogEntry(item: item)
                        }
                    }
                }
            }
            .padding(24)
        }
    }

    private var headerCard: some View {
        PreferenceCard(
            "Recent Activity",
            detail: "Inspect raw and cleaned output, then reuse text if needed.",
            icon: "clock.arrow.circlepath"
        ) {
            HStack {
                PreferenceBadge(
                    title: "\(appState.historyStore.items.count) saved",
                    tone: .neutral
                )

                Spacer()

                if !appState.historyStore.items.isEmpty {
                    Button("Clear History") {
                        appState.historyStore.clear()
                    }
                    .buttonStyle(.sophiieSecondary)
                }
            }
        }
    }
}

private struct RunLogEntry: View {
    let item: PipelineResult

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withSophiieAnimation {
                    isExpanded.toggle()
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.cleanedText)
                            .font(SophiieTheme.Typography.label)
                            .foregroundStyle(SophiieTheme.Palette.ink)
                            .lineLimit(isExpanded ? nil : 2)
                            .multilineTextAlignment(.leading)

                        Text(item.timestamp.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(SophiieTheme.Palette.muted)
                    }

                    Spacer()

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .foregroundStyle(SophiieTheme.Palette.muted)
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    transcriptBlock("Cleaned", item.cleanedText)
                    transcriptBlock("Raw", item.rawTranscript)

                    HStack(spacing: 10) {
                        PreferenceBadge(title: item.sttProvider.displayName, tone: .neutral)
                        PreferenceBadge(title: item.llmProvider.displayName, tone: .neutral)

                        if let llmModel = item.llmModel {
                            PreferenceBadge(title: llmModel, tone: .neutral)
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(16)
        .background(SophiieTheme.Palette.surfaceSubtle, in: RoundedRectangle(cornerRadius: SophiieTheme.Radius.card, style: .continuous))
    }

    private func transcriptBlock(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(SophiieTheme.Palette.muted)

            Text(text)
                .font(SophiieTheme.Typography.mono)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(SophiieTheme.Palette.surfaceSubtle, in: RoundedRectangle(cornerRadius: SophiieTheme.Radius.small, style: .continuous))
        }
    }
}
