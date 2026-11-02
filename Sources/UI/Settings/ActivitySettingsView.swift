import SwiftUI

/// Activity: the saved dictations, newest first, each expandable to the
/// cleaned and raw transcript. Failed dictations offer Retry and Delete.
struct ActivitySettingsView: View {
    @ObservedObject var historyStore: PipelineHistoryStore
    @ObservedObject var retrier: FailedDictationRetrier
    @ObservedObject var evalCases: MyEvalCaseStore
    /// The dictionary terms to save with a marked case.
    var vocabulary: () -> [String] = { [] }
    /// Opens this entry expanded (renders).
    var initiallyExpanded: UUID?
    let onRetry: (UUID) -> Void

    @State private var markingItem: PipelineResult?

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
                                    ActivityEntry(
                                        item: item,
                                        isMarkedWrong: evalCases.isMarked(item.id),
                                        startsExpanded: item.id == initiallyExpanded,
                                        onMarkWrong: { markingItem = item }
                                    )
                                }
                            }
                        }
                    }
                }
                evalCasesFooter
            }
        }
        .sheet(item: $markingItem) { item in
            MarkAsWrongSheet(
                item: item,
                onSave: { expected, tags in
                    let saved = evalCases.append(MyEvalCase(
                        id: MyEvalCase.makeID(dictationID: item.id, at: Date()),
                        input: item.rawTranscript,
                        expected: expected,
                        vocabulary: vocabulary(),
                        tags: tags
                    ))
                    if saved { markingItem = nil }
                },
                onCancel: { markingItem = nil }
            )
        }
    }

    /// Where marked dictations go, and a way to find the file.
    private var evalCasesFooter: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "checklist")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(SophiieTheme.Palette.muted)
                .accessibilityHidden(true)
            Text(evalCasesSummary)
                .font(.system(size: 11.5))
                .foregroundStyle(evalCases.lastError == nil ? SophiieTheme.Palette.muted : SophiieTheme.Palette.danger)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            TextAction(title: "Reveal file", systemImage: "folder") { evalCases.reveal() }
                .help(evalCases.fileURL.path)
        }
        .padding(.horizontal, 4)
    }

    private var evalCasesSummary: String {
        if let error = evalCases.lastError { return "Couldn't save the case: \(error)" }
        switch evalCases.count {
        case 0: return "Dictations you mark as wrong become private test cases in MyEvalCases.jsonl, on this Mac only."
        case 1: return "1 dictation marked as wrong, saved in MyEvalCases.jsonl on this Mac only."
        default: return "\(evalCases.count) dictations marked as wrong, saved in MyEvalCases.jsonl on this Mac only."
        }
    }
}

private struct ActivityEntry: View {
    let item: PipelineResult
    let isMarkedWrong: Bool
    let onMarkWrong: () -> Void

    @State private var isExpanded: Bool

    init(item: PipelineResult, isMarkedWrong: Bool, startsExpanded: Bool, onMarkWrong: @escaping () -> Void) {
        self.item = item
        self.isMarkedWrong = isMarkedWrong
        self.onMarkWrong = onMarkWrong
        _isExpanded = State(initialValue: startsExpanded)
    }

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
            .contextMenu {
                Button("Mark as Wrong…", action: onMarkWrong)
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    transcriptBlock(item.isCleanupOff ? "Pasted" : "Cleaned", item.cleanedText)
                    transcriptBlock("Raw", item.rawTranscript)
                    HStack(spacing: 8) {
                        PreferenceBadge(title: item.sttProvider.displayName, tone: .neutral)
                        if let from = item.sttFallbackFrom {
                            PreferenceBadge(title: "Filled in for \(from.displayName)", tone: .neutral)
                                .help("\(from.displayName)'s model wasn't downloaded yet, so \(item.sttProvider.displayName) transcribed this one.")
                        }
                        if item.isCleanupOff {
                            PreferenceBadge(title: "Cleanup off", tone: .neutral)
                                .help("Clean up with AI was off: Whispur pasted what the speech engine heard, with spoken edits and text fixes applied.")
                        } else {
                            PreferenceBadge(title: item.llmProvider.displayName, tone: .neutral)
                            if let llmModel = item.llmModel {
                                PreferenceBadge(title: llmModel, tone: .neutral)
                            }
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
                        Spacer(minLength: 8)
                        if isMarkedWrong {
                            Label("Marked as wrong", systemImage: "checkmark")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(SophiieTheme.Palette.muted)
                        } else {
                            TextAction(title: "Mark as wrong", systemImage: "flag", action: onMarkWrong)
                                .help("Save this dictation as a private test case for the cleanup prompt")
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
        var parts = [item.sttProviderSummary]
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
