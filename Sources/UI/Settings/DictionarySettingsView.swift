import SwiftUI

/// The Dictionary page: search, add and remove terms, see where each one
/// came from, edit how each one is misheard ("Heard as"), and turn learning
/// from edits on or off.
struct DictionarySettingsView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var vocabulary: VocabularyStore

    @State private var query = ""
    @State private var filter: VocabularyStore.Filter = .all
    @State private var draft = ""
    @State private var duplicateNotice: String?
    @FocusState private var focus: Field?

    private enum Field {
        case search
        case add
    }

    var body: some View {
        SettingsPage {
            PageHeader(
                SettingsTab.dictionary.title,
                pill: DictationSettingsView.termCountLabel(vocabulary.terms.count),
                subtitle: SettingsTab.dictionary.summary
            ) {
                Button {
                    focus = .add
                } label: {
                    Label("Add term", systemImage: "plus")
                }
                .buttonStyle(.sophiiePrimary)
            }

            HStack(spacing: 10) {
                searchField
                FilterChips(selection: $filter)
            }

            SettingsSection("Terms") {
                SettingsCard {
                    addRow
                    let shown = VocabularyStore.filter(vocabulary.terms, query: query, filter: filter)
                    if shown.isEmpty {
                        CardDivider(leadingInset: 0)
                        Text(emptyMessage)
                            .font(.system(size: 13))
                            .foregroundStyle(SophiieTheme.Palette.muted)
                            .padding(.vertical, 12)
                    } else {
                        ForEach(shown) { term in
                            CardDivider(leadingInset: 0)
                            TermRow(
                                term: term,
                                isCommonWord: CommonWords.isCommon,
                                onRemove: { vocabulary.remove(id: term.id) },
                                onAddAlias: { vocabulary.addAlias($0, to: term.id) },
                                onRemoveAlias: { vocabulary.removeAlias($0, from: term.id) },
                                onAlwaysReplace: { vocabulary.setAlwaysReplace($0, for: term.id) }
                            )
                        }
                    }
                }
            }

            SettingsCard {
                SettingsRow(
                    icon: "wand.and.stars",
                    title: "Learn from my edits",
                    subtitle: "Suggest a term when you correct a word Whispur got wrong"
                ) {
                    SettingsSwitch(label: "Learn from my edits", isOn: $appState.learnFromEdits)
                }
            }
        }
    }

    private var emptyMessage: String {
        if vocabulary.terms.isEmpty {
            return "No terms yet. Add names, products, and jargon Whispur should spell your way."
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return "No terms match \u{201C}\(trimmed)\u{201D}."
        }
        return filter == .learned ? "Nothing learned yet." : "No terms you added yet."
    }

    // MARK: - Search

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(SophiieTheme.Palette.muted)
                .accessibilityHidden(true)
            TextField("Search terms", text: $query, prompt: Text("Search terms").foregroundStyle(SophiieTheme.Palette.muted))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focus, equals: .search)
            if !query.isEmpty {
                InlineIconButton(systemName: "xmark.circle.fill", label: "Clear search") { query = "" }
            }
        }
        .sophiieField(isFocused: focus == .search)
    }

    // MARK: - Add

    private var addRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(SophiieTheme.Palette.interactive)
                    .accessibilityHidden(true)
                TextField(
                    "New term",
                    text: $draft,
                    prompt: Text("Add a word or phrase, like a name or product").foregroundStyle(SophiieTheme.Palette.muted)
                )
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($focus, equals: .add)
                    .onSubmit(addDraft)
                    .onChange(of: draft) { _, _ in duplicateNotice = nil }
                    .accessibilityLabel("New term")
                Button(action: addDraft) {
                    KeycapView(key: "\u{21A9}")
                }
                .buttonStyle(.plain)
                .disabled(VocabularyStore.normalized(draft).isEmpty)
                .help("Add term")
                .accessibilityLabel("Add term")
            }
            if let duplicateNotice {
                Text(duplicateNotice)
                    .font(SophiieTheme.Typography.caption)
                    .foregroundStyle(SophiieTheme.Palette.muted)
                    .padding(.leading, 25)
            }
        }
        .padding(.vertical, 12)
    }

    private func addDraft() {
        let cleaned = VocabularyStore.normalized(draft)
        guard !cleaned.isEmpty else { return }
        if vocabulary.add(cleaned) {
            draft = ""
            duplicateNotice = nil
        } else {
            duplicateNotice = "\u{201C}\(cleaned)\u{201D} is already in your dictionary."
        }
        focus = .add
    }
}

struct TermRow: View {
    private typealias Palette = SophiieTheme.Palette

    let term: VocabularyTerm
    let isCommonWord: (String) -> Bool
    let onRemove: () -> Void
    let onAddAlias: (String) -> Bool
    let onRemoveAlias: (String) -> Void
    let onAlwaysReplace: (Bool) -> Void
    /// Opens with the "Heard as" field showing (renders).
    var startsAdding = false

    @State private var isAdding = false
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    /// Aliases that are ordinary words or names: cleanup decides them from
    /// context unless "Always replace" is on.
    private var ambiguous: [String] {
        term.aliases.filter { !VocabularyAliasPlan.isClearCut(alias: $0, term: term.text, isCommonWord: isCommonWord) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(term.text)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(term.note())
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                if term.isLearned {
                    Label("Learned", systemImage: "sparkle")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.interactive)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Palette.surfaceSelected, in: Capsule())
                        .fixedSize()
                        .accessibilityHidden(true)
                }
                if term.aliases.isEmpty, !isAdding {
                    Button(action: startAdding) {
                        Image(systemName: "ear")
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.muted)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Add how \(term.text) gets misheard")
                    .accessibilityLabel("Add a heard-as spelling for \(term.text)")
                }
                Button(action: onRemove) {
                    Image(systemName: "minus.circle")
                        .font(.system(size: 14))
                        .foregroundStyle(Palette.muted)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Remove \(term.text)")
                .accessibilityLabel("Remove \(term.text)")
            }
            if !term.aliases.isEmpty || isAdding {
                heardAsRow
            }
            if !ambiguous.isEmpty {
                alwaysReplaceRow
            }
        }
        .padding(.vertical, 8)
        .onAppear { if startsAdding { isAdding = true } }
    }

    private var heardAsRow: some View {
        FlowLayout(spacing: 6) {
            Text("Heard as")
                .font(SophiieTheme.Typography.captionStrong)
                .foregroundStyle(Palette.muted)
                .padding(.trailing, 2)
            ForEach(term.aliases, id: \.self) { alias in
                AliasChip(
                    text: alias,
                    isAmbiguous: !term.alwaysReplace && ambiguous.contains(alias),
                    onRemove: { onRemoveAlias(alias) }
                )
            }
            if isAdding {
                TextField("Misheard as", text: $draft, prompt: Text("Misheard as\u{2026}").foregroundStyle(Palette.muted))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .frame(width: 130)
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background(Palette.surface, in: Capsule())
                    .overlay(Capsule().inset(by: 0.5).strokeBorder(Palette.highlight.opacity(0.55), lineWidth: 1))
                    .focused($fieldFocused)
                    .onSubmit(commit)
                    .onChange(of: fieldFocused) { _, focused in if !focused { commit() } }
                    .onExitCommand { isAdding = false; draft = "" }
                    .accessibilityLabel("Add a spelling \(term.text) is heard as")
            } else if term.aliases.count < VocabularyTerm.aliasLimit {
                Button(action: startAdding) {
                    Label("Add", systemImage: "plus")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Palette.interactive)
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Add a spelling speech engines write instead of \(term.text)")
                .accessibilityLabel("Add a heard-as spelling for \(term.text)")
            }
        }
    }

    private var alwaysReplaceRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Toggle("Always replace", isOn: Binding(get: { term.alwaysReplace }, set: onAlwaysReplace))
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
                .foregroundStyle(Palette.inkSecondary)
                .fixedSize()
            Text(alwaysReplaceNote)
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var alwaysReplaceNote: String {
        let quoted = ambiguous.map { "\u{201C}\($0)\u{201D}" }.joined(separator: ", ")
        if term.alwaysReplace {
            return "\(quoted) always becomes \(term.text), even when you mean the word."
        }
        let noun = ambiguous.count == 1 ? "is an ordinary word or name" : "are ordinary words or names"
        return "\(quoted) \(noun): cleanup fixes \(ambiguous.count == 1 ? "it" : "them") only when the sentence is about \(term.text)."
    }

    private func startAdding() {
        isAdding = true
        fieldFocused = true
    }

    private func commit() {
        let cleaned = VocabularyStore.normalized(draft)
        if cleaned.isEmpty || onAddAlias(cleaned) {
            draft = ""
            isAdding = false
        }
    }
}

/// One "heard as" spelling, with a remove button. Ambiguous ones (ordinary
/// words) are drawn dashed: cleanup decides them.
private struct AliasChip: View {
    private typealias Palette = SophiieTheme.Palette

    let text: String
    let isAmbiguous: Bool
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.inkSecondary)
                .lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(Palette.muted)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(text)")
        }
        .padding(.leading, 9)
        .padding(.trailing, 5)
        .frame(height: 24)
        .background(isAmbiguous ? Color.clear : Palette.surfaceSubtle, in: Capsule())
        .overlay(
            Capsule().inset(by: 0.5).strokeBorder(
                Palette.hairlineStrong,
                style: StrokeStyle(lineWidth: 1, dash: isAmbiguous ? [3, 2.5] : [])
            )
        )
        .help(isAmbiguous
              ? "An ordinary word or name: cleanup replaces it only when the sentence is about the term."
              : "Replaced in code on every dictation, cleanup on or off.")
    }
}

/// Segmented filter: All, Added by you, Learned.
private struct FilterChips: View {
    @Binding var selection: VocabularyStore.Filter

    var body: some View {
        HStack(spacing: 2) {
            ForEach(VocabularyStore.Filter.allCases) { option in
                let isSelected = option == selection
                Button {
                    selection = option
                } label: {
                    Text(option.rawValue)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? SophiieTheme.Palette.ink : SophiieTheme.Palette.muted)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: SophiieTheme.Radius.small, style: .continuous)
                                .fill(isSelected ? SophiieTheme.Palette.surface : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(3)
        .background(SophiieTheme.Palette.surfaceSubtle, in: RoundedRectangle(cornerRadius: SophiieTheme.Radius.control, style: .continuous))
        .fixedSize()
    }
}
