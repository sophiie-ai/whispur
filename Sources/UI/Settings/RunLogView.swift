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
                            .foregroundStyle(.secondary)
                    }
                } else {
                    VStack(spacing: 12) {
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
                    .buttonStyle(.bordered)
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
                withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.cleanedText)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(isExpanded ? nil : 2)
                            .multilineTextAlignment(.leading)

                        Text(item.timestamp.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .foregroundStyle(.secondary)
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
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func transcriptBlock(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}
