import SwiftUI

/// Custom prompts and vocabulary configuration.
struct PromptsSettingsView: View {
    @ObservedObject var appState: AppState
    @State private var showsDefaultPrompt = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                promptCard
                vocabularyCard
                referenceCard
            }
            .padding(24)
        }
    }

    private var promptCard: some View {
        PreferenceCard(
            "Cleanup Prompt",
            detail: "Adjust the instructions Whispur sends before transcript cleanup.",
            icon: "text.bubble"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                TextEditor(text: $appState.customSystemPrompt)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 180)
                    .padding(10)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                HStack {
                    PreferenceBadge(
                        title: appState.customSystemPrompt.isEmpty ? "Using default prompt" : "Using custom prompt",
                        tone: appState.customSystemPrompt.isEmpty ? .neutral : .good
                    )

                    Spacer()

                    if !appState.customSystemPrompt.isEmpty {
                        Button("Reset to Default") {
                            appState.customSystemPrompt = ""
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    private var vocabularyCard: some View {
        PreferenceCard(
            "Custom Vocabulary",
            detail: "One term per line. Useful for product names, acronyms, and proper nouns.",
            icon: "text.book.closed"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                TextEditor(text: $appState.customVocabulary)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 120)
                    .padding(10)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                Toggle(isOn: $appState.learnFromEdits) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Learn from my edits")
                            .font(.callout.weight(.medium))
                        Text("After a paste, Whispur re-reads the focused text field on your next dictation. If you changed a word, it asks before adding that word to this vocabulary.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
            }
        }
    }

    private var referenceCard: some View {
        PreferenceCard(
            "Default Reference",
            detail: "Use this as the baseline if you want to experiment and come back later.",
            icon: "doc.text.magnifyingglass"
        ) {
            DisclosureGroup(isExpanded: $showsDefaultPrompt) {
                Text(Prompts.defaultCleanup)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            } label: {
                Button(action: { withAnimation { showsDefaultPrompt.toggle() } }) {
                    Text("Show default cleanup prompt")
                        .contentShape(Rectangle())
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
