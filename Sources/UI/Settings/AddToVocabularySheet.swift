import SwiftUI

/// "Add to vocabulary…" from Activity: the correct spelling of a word
/// Whispur misheard, and how it was heard. Prefilled from the first
/// difference between the raw and cleaned text; clicking a word of the raw
/// transcript puts it in "Heard as".
struct AddToVocabularySheet: View {
    private typealias Palette = SophiieTheme.Palette

    let item: PipelineResult
    let isCommonWord: (String) -> Bool
    let onSave: (_ term: String, _ heardAs: String) -> Void
    let onCancel: () -> Void

    @State private var term: String
    @State private var heardAs: String

    init(
        item: PipelineResult,
        isCommonWord: @escaping (String) -> Bool = CommonWords.isCommon,
        onSave: @escaping (_ term: String, _ heardAs: String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.item = item
        self.isCommonWord = isCommonWord
        self.onSave = onSave
        self.onCancel = onCancel
        let suggestion = HeardAsSuggestion.from(raw: item.rawTranscript, cleaned: item.cleanedText)
        _term = State(initialValue: suggestion?.term ?? "")
        _heardAs = State(initialValue: suggestion?.heardAs ?? "")
    }

    private var cleanedTerm: String { VocabularyStore.normalized(term) }
    private var cleanedHeardAs: String { VocabularyStore.normalized(heardAs) }

    private var canSave: Bool {
        !cleanedTerm.isEmpty && !cleanedHeardAs.isEmpty && cleanedTerm.lowercased() != cleanedHeardAs.lowercased()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Add to vocabulary")
                    .font(SophiieTheme.Typography.title)
                    .foregroundStyle(Palette.ink)
                Text("Teach Whispur a word it mishears, and how it hears it.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.muted)
            }

            VStack(alignment: .leading, spacing: 6) {
                label("What you said (raw). Click the misheard word.")
                FlowLayout(spacing: 4, lineSpacing: 4) {
                    ForEach(Array(HeardAsSuggestion.words(item.rawTranscript).enumerated()), id: \.offset) { _, word in
                        WordButton(word: word, isSelected: word.lowercased() == cleanedHeardAs.lowercased()) {
                            heardAs = word
                        }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.surfaceSubtle, in: RoundedRectangle(cornerRadius: SophiieTheme.Radius.small, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 6) {
                label("What Whispur wrote")
                Text(item.cleanedText)
                    .font(SophiieTheme.Typography.mono)
                    .foregroundStyle(Palette.inkSecondary)
                    .textSelection(.enabled)
                    .lineLimit(4)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.surfaceSubtle, in: RoundedRectangle(cornerRadius: SophiieTheme.Radius.small, style: .continuous))
            }

            HStack(alignment: .top, spacing: 12) {
                field("Heard as", text: $heardAs, prompt: "Whisper")
                Image(systemName: "arrow.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.muted)
                    .padding(.top, 30)
                    .accessibilityHidden(true)
                field("Correct spelling", text: $term, prompt: "Whispur")
            }

            if canSave {
                Label(outcome, systemImage: isAmbiguous ? "sparkles" : "checkmark.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.sophiieSecondary)
                    .keyboardShortcut(.cancelAction)
                Button("Add") { onSave(cleanedTerm, cleanedHeardAs) }
                    .buttonStyle(.sophiiePrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(22)
        .frame(width: 520)
        .background(Palette.surfaceWarm)
    }

    private var isAmbiguous: Bool {
        !VocabularyAliasPlan.isClearCut(alias: cleanedHeardAs, term: cleanedTerm, isCommonWord: isCommonWord)
    }

    /// What will happen to the spelling once it's saved.
    private var outcome: String {
        let heard = "\u{201C}\(cleanedHeardAs)\u{201D}"
        let written = "\u{201C}\(cleanedTerm)\u{201D}"
        if isAmbiguous {
            return "\(heard) is also an ordinary word or name, so cleanup writes \(written) only when the sentence is about it. Turn on Always replace in Dictionary to change it every time."
        }
        return "Whispur will write \(written) whenever it hears \(heard), with cleanup on or off."
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(SophiieTheme.Typography.captionStrong)
            .foregroundStyle(Palette.muted)
    }

    private func field(_ title: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            label(title)
            TextField(title, text: text, prompt: Text(prompt).foregroundStyle(Palette.muted))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: SophiieTheme.Radius.control, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: SophiieTheme.Radius.control, style: .continuous)
                        .strokeBorder(Palette.controlBorder.opacity(0.6), lineWidth: 1)
                )
                .accessibilityLabel(title)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct WordButton: View {
    private typealias Palette = SophiieTheme.Palette

    let word: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(word)
                .font(SophiieTheme.Typography.mono)
                .foregroundStyle(isSelected ? Palette.ink : Palette.inkSecondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(isSelected ? Palette.surfaceSelected : Color.clear, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(isSelected ? Palette.highlight.opacity(0.55) : Color.clear, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
