import SwiftUI

/// The Dictionary page: search, add and remove terms, see where each one
/// came from, and turn learning from edits on or off.
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
                            TermRow(term: term) { vocabulary.remove(id: term.id) }
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

private struct TermRow: View {
    let term: VocabularyTerm
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(term.text)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(SophiieTheme.Palette.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(term.note())
                    .font(.system(size: 12))
                    .foregroundStyle(SophiieTheme.Palette.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            if term.isLearned {
                Label("Learned", systemImage: "sparkle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SophiieTheme.Palette.interactive)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(SophiieTheme.Palette.surfaceSelected, in: Capsule())
                    .fixedSize()
                    .accessibilityHidden(true)
            }
            Button(action: onRemove) {
                Image(systemName: "minus.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(SophiieTheme.Palette.muted)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Remove \(term.text)")
            .accessibilityLabel("Remove \(term.text)")
        }
        .padding(.vertical, 8)
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
