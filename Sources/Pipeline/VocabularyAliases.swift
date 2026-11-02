import Foundation

/// A dictionary term with the spellings a transcript shows instead of it.
struct VocabularyAliasEntry: Equatable {
    let term: String
    let aliases: [String]
    /// Replace every alias in code, even one that is an ordinary word.
    var alwaysReplace = false
}

/// One phrase replaced in code, and the term it becomes.
struct VocabularyReplacement: Equatable {
    let phrase: String
    let term: String
}

/// What happens to each "heard as" spelling.
///
/// - Clear-cut aliases are replaced in code, before cleanup and with
///   cleanup off: a single word that isn't an ordinary word ("Wispur",
///   "Hanx"), a phrase that is the term split up ("open code" for
///   "OpenCode"), or a phrase with a word that isn't ordinary.
/// - Ambiguous aliases (ordinary words and names: "Whisper", "Sophie",
///   "Hanks", "Whisper app") are never replaced in code, because they are
///   often meant as written ("I use Whisper from OpenAI", "Sophie from
///   accounting called"). They go to cleanup as hints next to the term
///   ("Whispur (heard as: Whisper)"), and the model decides from context.
///   "Always replace" on a term makes all its aliases clear-cut.
///
/// An alias that is itself a dictionary term, or one two terms claim, is
/// dropped: replacing it would rewrite a word the user listed.
struct VocabularyAliasPlan: Equatable {
    var replacements: [VocabularyReplacement] = []
    /// Term -> ambiguous aliases, for the cleanup prompt.
    var heardAs: [String: [String]] = [:]

    static let empty = VocabularyAliasPlan()

    static func build(
        entries: [VocabularyAliasEntry],
        terms: [String],
        isCommonWord: (String) -> Bool
    ) -> VocabularyAliasPlan {
        let listed = Set((terms + entries.map(\.term)).map { $0.lowercased() })
        var claims: [String: Int] = [:]
        for entry in entries {
            for alias in Set(entry.aliases.map { normalized($0).lowercased() }) { claims[alias, default: 0] += 1 }
        }
        var plan = VocabularyAliasPlan()
        for entry in entries {
            var hints: [String] = []
            var seen = Set<String>()
            for raw in entry.aliases {
                let alias = normalized(raw)
                let key = alias.lowercased()
                guard !alias.isEmpty, seen.insert(key).inserted, !listed.contains(key), claims[key] == 1 else { continue }
                if entry.alwaysReplace || isClearCut(alias: alias, term: entry.term, isCommonWord: isCommonWord) {
                    plan.replacements.append(VocabularyReplacement(phrase: alias, term: entry.term))
                } else {
                    hints.append(alias)
                }
            }
            if !hints.isEmpty { plan.heardAs[entry.term] = hints }
        }
        return plan
    }

    /// Whether an alias is safe to replace in code without asking.
    static func isClearCut(alias: String, term: String, isCommonWord: (String) -> Bool) -> Bool {
        let words = alias.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count > 1 else { return !isCommonWord(alias) }
        if letters(alias) == letters(term) { return true }
        return words.contains { !isCommonWord($0) }
    }

    private static func letters(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// Replaces "heard as" phrases with their terms, as whole phrases.
///
/// Ported from Hex's `text_replacements.rs` (MIT): case-insensitive matches
/// on phrase boundaries, the longest match wins where two overlap,
/// replacements never feed into each other, and a match rejected for
/// touching a word resumes one character later, so an overlapping phrase is
/// still found (Hex #139). Next to scripts written without spaces (CJK,
/// Thai, ...) a letter doesn't count as touching (Hex #177), so "用open
/// code写" still becomes "用OpenCode写".
///
/// Added here: a phrase inside an address, path, handle or hyphenated word
/// ("sophie@acme.io", "acme.io/sophie", "Sophie-Anne") is left alone. The
/// term is written exactly as it is spelled in the dictionary.
enum VocabularyAliasReplacer {
    private struct Candidate {
        let range: Range<String.Index>
        let length: Int
        let rule: Int
    }

    static func apply(_ replacements: [VocabularyReplacement], to text: String) -> String {
        guard !replacements.isEmpty, !text.isEmpty else { return text }
        var candidates: [Candidate] = []
        for (rule, replacement) in replacements.enumerated() where !replacement.phrase.isEmpty {
            var from = text.startIndex
            while from < text.endIndex,
                  let found = text.range(of: replacement.phrase, options: [.caseInsensitive], range: from..<text.endIndex) {
                if isPhraseBoundary(text, found) {
                    candidates.append(Candidate(range: found, length: text.distance(from: found.lowerBound, to: found.upperBound), rule: rule))
                    from = found.upperBound
                } else {
                    from = text.index(after: found.lowerBound)
                }
            }
        }
        guard !candidates.isEmpty else { return text }
        candidates.sort { left, right in
            if left.length != right.length { return left.length > right.length }
            if left.range.lowerBound != right.range.lowerBound { return left.range.lowerBound < right.range.lowerBound }
            return left.rule < right.rule
        }
        var selected: [Candidate] = []
        for candidate in candidates where !selected.contains(where: { $0.range.overlaps(candidate.range) }) {
            selected.append(candidate)
        }
        selected.sort { $0.range.lowerBound < $1.range.lowerBound }
        var output = ""
        var cursor = text.startIndex
        for candidate in selected {
            output += text[cursor..<candidate.range.lowerBound]
            output += replacements[candidate.rule].term
            cursor = candidate.range.upperBound
        }
        output += text[cursor...]
        return output
    }

    private static func isPhraseBoundary(_ text: String, _ range: Range<String.Index>) -> Bool {
        let before = range.lowerBound > text.startIndex ? text[text.index(before: range.lowerBound)] : nil
        let after = range.upperBound < text.endIndex ? text[range.upperBound] : nil
        if let before, isWordCharacter(before) || "@/\\-_#".contains(before) { return false }
        if let after, isWordCharacter(after) || "@/\\-_".contains(after) { return false }
        // "acme.sophie" / "sophie.dev": part of a domain or file name.
        if before == ".", range.lowerBound > text.index(after: text.startIndex) {
            let beforeDot = text[text.index(range.lowerBound, offsetBy: -2)]
            if beforeDot.isLetterOrNumber { return false }
        }
        if after == ".", text.index(after: range.upperBound) < text.endIndex {
            let afterDot = text[text.index(after: range.upperBound)]
            if afterDot.isLetterOrNumber { return false }
        }
        return true
    }

    private static func isWordCharacter(_ c: Character) -> Bool {
        (c.isLetterOrNumber || c == "_") && !TextScan.isUnspacedScript(c)
    }
}
