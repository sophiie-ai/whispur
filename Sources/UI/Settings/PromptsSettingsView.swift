import SwiftUI

/// Custom prompts and vocabulary configuration.
struct PromptsSettingsView: View {
    @ObservedObject var appState: AppState
    @State private var showsDefaultPrompt = false
    @State private var editingModeID: DictationModeID = .general

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                modesCard
                promptCard
                vocabularyCard
                referenceCard
            }
            .padding(24)
        }
        .onAppear { editingModeID = appState.selectedModeID }
    }

    private var modesCard: some View {
        PreferenceCard(
            "Dictation Modes",
            detail: "Switch cleanup instructions based on what you're writing. Each mode ships a sensible default; customize any of them to match your voice.",
            icon: "square.stack.3d.up"
        ) {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Editing", selection: $editingModeID) {
                    ForEach(DictationModeID.allCases) { mode in
                        Label(mode.displayName, systemImage: mode.icon).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Text(editingModeID.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ModePromptEditor(
                    modeID: editingModeID,
                    modeStore: appState.modeStore
                )

                HStack(spacing: 8) {
                    PreferenceBadge(
                        title: appState.selectedModeID == editingModeID ? "Active mode" : "Not active",
                        tone: appState.selectedModeID == editingModeID ? .good : .neutral
                    )

                    Spacer()

                    if appState.selectedModeID != editingModeID {
                        Button("Use this mode") {
                            appState.selectedModeID = editingModeID
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private var promptCard: some View {
        PreferenceCard(
            "Global Override Prompt",
            detail: "Optional. When set, this replaces every mode's prompt for every dictation. Leave empty to use the per-mode prompts above.",
            icon: "text.bubble"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                TextEditor(text: $appState.customSystemPrompt)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 140)
                    .padding(10)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                HStack {
                    PreferenceBadge(
                        title: appState.customSystemPrompt.isEmpty ? "Using mode prompts" : "Global override active",
                        tone: appState.customSystemPrompt.isEmpty ? .neutral : .warning
                    )

                    Spacer()

                    if !appState.customSystemPrompt.isEmpty {
                        Button("Clear override") {
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
                Text(editingModeID.defaultPrompt)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            } label: {
                Button(action: { withAnimation { showsDefaultPrompt.toggle() } }) {
                    Text("Show default prompt for \(editingModeID.displayName)")
                        .contentShape(Rectangle())
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct ModePromptEditor: View {
    let modeID: DictationModeID
    @ObservedObject var modeStore: DictationModeStore
    @State private var draft: String = ""
    @State private var isCustomized: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $draft)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 180)
                .padding(10)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .onChange(of: draft) { _, new in
                    // Only treat non-empty drafts as customizations. Wiping
                    // the editor should reset the mode to its baked-in prompt.
                    if new.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        modeStore.setCustomPrompt("", for: modeID)
                        isCustomized = false
                    } else if new != modeID.defaultPrompt {
                        modeStore.setCustomPrompt(new, for: modeID)
                        isCustomized = true
                    } else {
                        modeStore.setCustomPrompt("", for: modeID)
                        isCustomized = false
                    }
                }

            HStack {
                PreferenceBadge(
                    title: isCustomized ? "Customized" : "Using default",
                    tone: isCustomized ? .good : .neutral
                )
                Spacer()
                if isCustomized {
                    Button("Reset to default") {
                        modeStore.setCustomPrompt("", for: modeID)
                        draft = modeID.defaultPrompt
                        isCustomized = false
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .onAppear { reload() }
        .onChange(of: modeID) { _, _ in reload() }
    }

    private func reload() {
        let resolved = modeStore.resolvedPrompt(for: modeID)
        draft = resolved
        isCustomized = modeStore.isCustomized(modeID)
    }
}

