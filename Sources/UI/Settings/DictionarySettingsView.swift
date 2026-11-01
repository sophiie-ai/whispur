import SwiftUI

/// The Dictionary page: the custom vocabulary and learning from edits.
struct DictionarySettingsView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        SettingsPage {
            PageHeader(
                SettingsTab.dictionary.title,
                pill: DictationSettingsView.termCountLabel(VocabularyParser.parse(appState.customVocabulary).count),
                subtitle: SettingsTab.dictionary.summary
            )

            SettingsSection("Terms", footer: "One term per line. Useful for product names, acronyms, and proper nouns.") {
                SettingsCard {
                    CardContent {
                        TextEditor(text: $appState.customVocabulary)
                            .font(.system(.body, design: .monospaced))
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 220)
                            .padding(8)
                            .background(SophiieTheme.Palette.surfaceSubtle, in: RoundedRectangle(cornerRadius: SophiieTheme.Radius.control, style: .continuous))
                            .accessibilityLabel("Custom vocabulary, one term per line")
                    }
                }
            }

            SettingsCard {
                SettingsRow(
                    icon: "wand.and.stars",
                    title: "Learn from my edits",
                    subtitle: "After a paste, Whispur re-reads the text field on your next dictation. If you changed a word, it asks before adding it here."
                ) {
                    SettingsSwitch(label: "Learn from my edits", isOn: $appState.learnFromEdits)
                }
            }
        }
    }
}
