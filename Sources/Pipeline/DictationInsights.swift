import Foundation

/// Counts behind the Insights page: the words you use that aren't everyday
/// words, when you dictate, which apps you dictate into, and the words you
/// fix. Stores counts only, never transcripts, and keeps every table
/// bounded so the file stays small however long you use Whispur.
struct DictationInsights: Codable, Equatable {
    /// One counted word, kept in the spelling it was last written in.
    struct Tally: Codable, Equatable {
        var display: String
        var count: Int
    }

    /// A weekday (1 = Sunday, as `Calendar` numbers them) and hour (0–23).
    struct Slot: Equatable {
        let weekday: Int
        let hour: Int
        let count: Int
    }

    /// Dictations recorded since insights began.
    private(set) var dictations = 0
    private(set) var words: [String: Tally] = [:]
    /// Dictations per weekday×hour, Sunday 00:00 first.
    private(set) var slots = [Int](repeating: 0, count: 7 * 24)
    /// Dictations per app bundle ID.
    private(set) var apps: [String: Int] = [:]
    private(set) var corrections: [String: Tally] = [:]

    /// Most distinct words kept. Past it the rarest are pruned down to
    /// `pruneTo`, which leaves room for new words to build up a count.
    static let wordLimit = 1000
    static let pruneTo = 800
    static let correctionLimit = 500
    static let appLimit = 200
    /// Dictations needed before the word, time and app highlights show.
    static let minimumDictations = 10

    // MARK: - Recording

    mutating func record(text: String, appBundleID: String?, at date: Date, calendar: Calendar, isCommon: (String) -> Bool) {
        dictations += 1

        let weekday = calendar.component(.weekday, from: date)
        let hour = calendar.component(.hour, from: date)
        slots[(weekday - 1) * 24 + hour] += 1

        if let appBundleID, !appBundleID.isEmpty {
            apps[appBundleID, default: 0] += 1
            Self.prune(&apps, to: Self.appLimit)
        }

        for word in Self.candidateWords(in: text) where !isCommon(word) {
            Self.add(word, to: &words)
        }
        if words.count > Self.wordLimit {
            Self.prune(&words, to: Self.pruneTo)
        }
    }

    /// Counts one fix of a word Whispur wrote.
    mutating func recordCorrection(_ word: String) {
        let trimmed = Self.trim(word)
        guard !trimmed.isEmpty else { return }
        Self.add(trimmed, to: &corrections)
        if corrections.count > Self.correctionLimit {
            Self.prune(&corrections, to: Self.correctionLimit * Self.pruneTo / Self.wordLimit)
        }
    }

    // MARK: - Highlights

    var topWord: Tally? { Self.top(words) }
    var topCorrection: Tally? { Self.top(corrections) }

    var topApp: (bundleID: String, count: Int)? {
        apps.max { ($0.value, $1.key) < ($1.value, $0.key) }.map { ($0.key, $0.value) }
    }

    /// The busiest weekday and hour; the earliest in the week wins a tie.
    var peakSlot: Slot? {
        guard let best = slots.max(), best > 0, let index = slots.firstIndex(of: best) else { return nil }
        return Slot(weekday: index / 24 + 1, hour: index % 24, count: best)
    }

    /// Dictations still needed before the word, time and app highlights
    /// show.
    var dictationsNeeded: Int { max(0, Self.minimumDictations - dictations) }

    // MARK: - Words

    /// Words worth counting: punctuation trimmed, at least two characters,
    /// at least one letter, no links or addresses.
    static func candidateWords(in text: String) -> [String] {
        text.split { $0.isWhitespace }.compactMap { token in
            guard !token.contains("/"), !token.contains("@") else { return nil }
            let word = trim(String(token))
            guard word.count >= 2, word.contains(where: \.isLetter) else { return nil }
            return word
        }
    }

    private static func trim(_ word: String) -> String {
        word.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols))
    }

    private static func add(_ word: String, to table: inout [String: Tally]) {
        let key = word.lowercased()
        table[key, default: Tally(display: word, count: 0)].count += 1
        table[key]?.display = word
    }

    private static func top(_ table: [String: Tally]) -> Tally? {
        table.max { ($0.value.count, $1.key) < ($1.value.count, $0.key) }?.value
    }

    /// Keeps the `limit` highest counts; ties keep the alphabetically first
    /// key so pruning is deterministic.
    private static func prune<Value>(_ table: inout [String: Value], to limit: Int, count: (Value) -> Int) {
        guard table.count > limit else { return }
        let kept = table.sorted { (count($0.value), $1.key) > (count($1.value), $0.key) }.prefix(limit)
        table = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
    }

    private static func prune(_ table: inout [String: Tally], to limit: Int) {
        prune(&table, to: limit, count: \.count)
    }

    private static func prune(_ table: inout [String: Int], to limit: Int) {
        prune(&table, to: limit, count: { $0 })
    }

    // MARK: - Decoding

    private enum CodingKeys: String, CodingKey {
        case dictations, words, slots, apps, corrections
    }

    init() {}

    /// Missing or malformed tables decode empty rather than failing the
    /// whole stats file.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dictations = (try? container.decodeIfPresent(Int.self, forKey: .dictations)) ?? 0
        words = (try? container.decodeIfPresent([String: Tally].self, forKey: .words)) ?? [:]
        apps = (try? container.decodeIfPresent([String: Int].self, forKey: .apps)) ?? [:]
        corrections = (try? container.decodeIfPresent([String: Tally].self, forKey: .corrections)) ?? [:]
        if let decoded = try? container.decodeIfPresent([Int].self, forKey: .slots), decoded.count == 7 * 24 {
            slots = decoded
        }
    }
}
