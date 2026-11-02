import Foundation

/// The "Add to vocabulary…" prefill for a dictation: the first place where
/// the cleaned text spelled a word differently from the raw transcript
/// ("ask sophie" → "Ask Sophiie": heard as "sophie", term "Sophiie").
///
/// Only substitutions of one to three words count, and not ones that only
/// change case, punctuation or a number's form ("five" → "5"): deleted
/// fillers and reformatted numbers are not vocabulary.
struct HeardAsSuggestion: Equatable {
    var term: String
    var heardAs: String

    static func from(raw: String, cleaned: String) -> HeardAsSuggestion? {
        let rawWords = words(FillerWords.remove(from: raw))
        let cleanedWords = words(cleaned)
        guard !rawWords.isEmpty, !cleanedWords.isEmpty else { return nil }
        for block in substitutions(rawWords.map(key), cleanedWords.map(key)) {
            let heard = rawWords[block.raw].joined(separator: " ")
            let term = cleanedWords[block.cleaned].joined(separator: " ")
            guard block.raw.count <= 3, block.cleaned.count <= 3,
                  term.contains(where: \.isLetter), heard.contains(where: \.isLetter)
            else { continue }
            return HeardAsSuggestion(term: term, heardAs: heard)
        }
        return nil
    }

    /// Words of a text with surrounding punctuation trimmed.
    static func words(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: .punctuationCharacters.union(.symbols).subtracting(CharacterSet(charactersIn: "#@+"))) }
            .filter { !$0.isEmpty }
    }

    private static func key(_ word: String) -> String {
        word.lowercased()
    }

    /// Replaced runs between the two word lists (both sides non-empty), in
    /// order, from a longest-common-subsequence alignment.
    private static func substitutions(_ a: [String], _ b: [String]) -> [(raw: Range<Int>, cleaned: Range<Int>)] {
        let n = a.count, m = b.count
        var lcs = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var blocks: [(Range<Int>, Range<Int>)] = []
        var i = 0, j = 0
        var startI = 0, startJ = 0
        func close() {
            if i > startI, j > startJ { blocks.append((startI..<i, startJ..<j)) }
        }
        while i < n, j < m {
            if a[i] == b[j] {
                close()
                i += 1
                j += 1
                startI = i
                startJ = j
            } else if lcs[i + 1][j] >= lcs[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        i = n
        j = m
        close()
        return blocks.map { (raw: $0.0, cleaned: $0.1) }
    }
}
