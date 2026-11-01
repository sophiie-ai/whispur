import SwiftUI

/// Activity: the saved dictations, newest first, each expandable to the
/// cleaned and raw transcript. Failed dictations offer Retry and Delete.
struct ActivitySettingsView: View {
    @ObservedObject var historyStore: PipelineHistoryStore
    @ObservedObject var retrier: FailedDictationRetrier
    let onRetry: (UUID) -> Void

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
                SettingsSection("Recent dictations", footer: "Whispur keeps your most recent dictations on this Mac. When one fails, its recording is kept for 24 hours so you can retry it, then deleted. Successful recordings are never kept.") {
                    SettingsCard {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(historyStore.items.enumerated()), id: \.element.id) { index, item in
                                if index > 0 { CardDivider(leadingInset: 0) }
                                if item.isFailed {
                                    FailedActivityEntry(
                                        item: item,
                                        canRetry: historyStore.canRetry(item),
                                        isRetrying: retrier.isRunning(item.id),
                                        onRetry: { onRetry(item.id) },
                                        onDelete: { retrier.delete(item.id) }
                                    )
                                } else {
                                    ActivityEntry(item: item)
                                }
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
                        // After "Use raw" the app holds the raw transcript.
                        Text(item.usedRawAt == nil ? item.cleanedText : item.rawTranscript)
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
                        if let style = item.style {
                            PreferenceBadge(title: "\(style.title) style", tone: .neutral)
                        }
                        if item.failure?.retriedAt != nil {
                            PreferenceBadge(title: "Retried", tone: .good)
                        }
                        if item.usedRawAt != nil {
                            PreferenceBadge(title: "Used raw", tone: .neutral)
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

/// A dictation that produced no text: the error, and Retry / Delete while
/// its recording is still kept.
struct FailedActivityEntry: View {
    let item: PipelineResult
    let canRetry: Bool
    let isRetrying: Bool
    let onRetry: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    PreferenceBadge(title: "Failed", tone: .critical)
                    Text(item.timestamp.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 11.5))
                        .foregroundStyle(SophiieTheme.Palette.muted)
                }
                Text(item.failure?.error ?? "The dictation failed.")
                    .font(.system(size: 13))
                    .foregroundStyle(SophiieTheme.Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(SophiieTheme.Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                if isRetrying {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Retrying")
                    Text("Retrying")
                        .font(.system(size: 12))
                        .foregroundStyle(SophiieTheme.Palette.muted)
                } else {
                    if canRetry {
                        Button("Retry", action: onRetry)
                            .buttonStyle(.sophiiePrimary)
                            .help("Transcribe the kept recording again and copy the text")
                    }
                    Button("Delete", action: onDelete)
                        .buttonStyle(.sophiieSecondary)
                        .help("Delete this entry and its recording")
                }
            }
            .fixedSize()
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .contain)
    }

    private var detail: String {
        var parts = [item.sttProvider.displayName]
        if let style = item.style { parts.append("\(style.title) style") }
        if !canRetry {
            parts.append("Recording no longer kept")
        } else {
            parts.append("Retry copies the text to the clipboard")
        }
        return parts.joined(separator: " · ")
    }
}

/// "Copied to clipboard" after a retry, at the bottom of the Settings window.
struct RetryToast: View {
    @ObservedObject var retrier: FailedDictationRetrier

    var body: some View {
        if let toast = retrier.toast {
            Label(toast, systemImage: "checkmark.circle.fill")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(SophiieTheme.Palette.ink)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(SophiieTheme.Palette.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(SophiieTheme.Palette.border, lineWidth: 1))
                .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
                .padding(.bottom, 20)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .accessibilityAddTraits(.updatesFrequently)
        }
    }
}
