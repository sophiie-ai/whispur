import Foundation

/// One dictionary term and where it came from.
struct VocabularyTerm: Codable, Identifiable, Equatable {
    enum Source: Codable, Equatable {
        /// Typed in by the user (or carried over from the old plain list).
        case manual
        /// Accepted from a correction the user made to a pasted dictation;
        /// `original` is the word Whispur had written.
        case learned(original: String)
    }

    let id: UUID
    let text: String
    let source: Source
    /// When the term was added. Nil for terms migrated from the old list.
    let addedAt: Date?

    init(id: UUID = UUID(), text: String, source: Source, addedAt: Date?) {
        self.id = id
        self.text = text
        self.source = source
        self.addedAt = addedAt
    }

    var isLearned: Bool {
        if case .learned = source { return true }
        return false
    }

    /// Longest snippet of the original word shown in "Learned from your edit
    /// of …".
    static let snippetLimit = 32

    /// The line under the term: "Added by you" or "Learned from your edit of
    /// “Sophie”", with the date when there is one.
    func note(dateFormat: (Date) -> String = { $0.formatted(.dateTime.day().month(.abbreviated)) }) -> String {
        let origin: String
        switch source {
        case .manual:
            origin = "Added by you"
        case let .learned(original):
            origin = "Learned from your edit of \u{201C}\(Self.snippet(original))\u{201D}"
        }
        guard let addedAt else { return origin }
        return "\(origin) \u{00B7} \(dateFormat(addedAt))"
    }

    static func snippet(_ text: String) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flat.count > snippetLimit else { return flat }
        return String(flat.prefix(snippetLimit - 1)).trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }
}

/// The user's dictionary. Each term records whether the user added it or
/// Whispur learned it from an edit.
///
/// Persisted as JSON under `vocabularyTerms`. The first load migrates the old
/// plain `customVocabulary` list (one term per line or comma separated) as
/// manual terms with no date. Every save also writes the plain list back to
/// `customVocabulary`, so an older build still sees the same terms.
@MainActor
final class VocabularyStore: ObservableObject {
    static let termsKey = "vocabularyTerms"
    static let legacyKey = "customVocabulary"

    @Published private(set) var terms: [VocabularyTerm] = []

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    /// Plain strings for everything that biases on vocabulary (STT prompts,
    /// the cleanup message).
    var plainTerms: [String] {
        terms.map(\.text)
    }

    func contains(_ text: String) -> Bool {
        let key = Self.normalized(text).lowercased()
        return terms.contains { $0.text.lowercased() == key }
    }

    /// Adds a term at the top of the list. Returns false when the term is
    /// empty or already present (case-insensitively).
    @discardableResult
    func add(_ text: String, source: VocabularyTerm.Source = .manual, at date: Date = Date()) -> Bool {
        let cleaned = Self.normalized(text)
        guard !cleaned.isEmpty, !contains(cleaned) else { return false }
        terms.insert(VocabularyTerm(text: cleaned, source: source, addedAt: date), at: 0)
        save()
        return true
    }

    func remove(id: VocabularyTerm.ID) {
        terms.removeAll { $0.id == id }
        save()
    }

    // MARK: - Filtering

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case manual = "Added by you"
        case learned = "Learned"

        var id: String { rawValue }

        func includes(_ term: VocabularyTerm) -> Bool {
            switch self {
            case .all: return true
            case .manual: return !term.isLearned
            case .learned: return term.isLearned
            }
        }
    }

    static func filter(_ terms: [VocabularyTerm], query: String, filter: Filter) -> [VocabularyTerm] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return terms.filter { term in
            filter.includes(term) && (needle.isEmpty || term.text.localizedCaseInsensitiveContains(needle))
        }
    }

    // MARK: - Persistence

    /// Trims surrounding whitespace and folds line breaks. Punctuation is
    /// kept: ".NET" and "C#" are real terms.
    static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func load() {
        if let data = defaults.data(forKey: Self.termsKey),
           let decoded = try? JSONDecoder().decode([VocabularyTerm].self, from: data) {
            terms = decoded
            return
        }
        // First run on this version: carry the plain list over as-is.
        let legacy = defaults.string(forKey: Self.legacyKey) ?? ""
        terms = VocabularyParser.parse(legacy).map { VocabularyTerm(text: $0, source: .manual, addedAt: nil) }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(terms) {
            defaults.set(data, forKey: Self.termsKey)
        }
        defaults.set(plainTerms.joined(separator: "\n"), forKey: Self.legacyKey)
    }
}
