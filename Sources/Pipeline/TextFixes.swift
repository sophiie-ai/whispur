import Foundation
import NaturalLanguage

/// Which deterministic text fixes run on a dictation.
///
/// Smart spacing is not here: it runs at paste time, against the field the
/// text goes into (`SmartSpacing`).
struct TextFixOptions: Equatable {
    var removeFillers = true
    var spokenSymbols = true
    var spokenQuotes = true
    /// Curly quotes for prose apps, straight quotes for code apps.
    var quoteStyle: SpokenQuotes.Style = .curly
    /// The languages the user speaks (BCP-47 codes, empty = auto-detect).
    /// "um" and "er" are real words in German, Dutch and the Scandinavian
    /// languages, so they are only removed when the dictation isn't in one.
    var spokenLanguages: [String] = []

    static let allOff = TextFixOptions(removeFillers: false, spokenSymbols: false, spokenQuotes: false)
}

/// Text fixes made in code, with no model involved: filler words removed,
/// spoken quotes and symbols written as characters.
///
/// They run on every dictation right after the spoken edit commands
/// (`VoiceCommands`), on the text cleanup receives when it is on and on the
/// text that is pasted when it is off or fails. Running them before cleanup
/// means the model sees "#release" instead of "hashtag release", and the
/// result doesn't depend on whether the model happened to convert it.
///
/// Every fix is a pure function of the text, applying it twice changes
/// nothing more, and each one only fires on a narrow, documented shape: when
/// in doubt the words are left as spoken.
///
/// Order: fillers first (so "hashtag um release" still joins), then quotes,
/// then symbols.
enum TextFixes {
    static func apply(_ text: String, options: TextFixOptions) -> String {
        var text = text
        if options.removeFillers {
            text = FillerWords.remove(
                from: text,
                keepingWordLikeFillers: FillerWords.umAndErAreWords(in: text, languages: options.spokenLanguages)
            )
        }
        if options.spokenQuotes { text = SpokenQuotes.apply(to: text, style: options.quoteStyle) }
        if options.spokenSymbols { text = SpokenSymbols.apply(to: text) }
        return text
    }
}

// MARK: - Filler words

/// Removes the hesitations speech engines write down verbatim: "um", "umm",
/// "uh", "uhh", "erm", "er", "ah", "hmm" (and longer runs of the same
/// letters, like "ummm").
///
/// Ported from Hex's Labs "Remove filler words" (MIT). A filler only matches
/// as a whole word, lowercase or with just its first letter capitalised, so
/// "umbrella", "ahead", "error", "ahí", "uh-huh", "ER" and "UM" stay. The
/// comma or ellipsis that came with a filler goes with it, the spaces around
/// it close up, and a capitalised filler that started a sentence hands its
/// capital to the next word. Line breaks are kept.
///
/// Kept on purpose:
/// - "um" and "er" in German, Dutch and Scandinavian dictations, where they
///   are words ("um drei", "er ist", "det er"): see `umAndErAreWords`.
/// - Words that are fillers only sometimes: "like", "so", "well", "you know",
///   Spanish "este" (also a demonstrative) and "eh" (also a tag question).
///   Cleanup handles those from context when it is on.
/// - A filler quoted as a word (`the "um" label`, "the word um").
///
/// An unquoted mention ("the um button") reads exactly like a hesitation and
/// is removed.
enum FillerWords {
    /// Whether `word` (letters only, already case-checked) is a filler.
    static func isFiller(_ word: String) -> Bool {
        switch word {
        case "erm", "er":
            return true
        default:
            break
        }
        let letters = Array(word)
        guard letters.count >= 2 else { return false }
        let rest = letters.dropFirst()
        switch letters[0] {
        case "u":
            // um, umm, ummm / uh, uhh, uhhh
            return rest.allSatisfy { $0 == "m" } || rest.allSatisfy { $0 == "h" }
        case "a":
            // ah, ahh
            return rest.allSatisfy { $0 == "h" }
        case "h":
            // hmm, hmmm (not "hm")
            return rest.count >= 2 && rest.allSatisfy { $0 == "m" }
        default:
            return false
        }
    }

    /// Languages where "um" or "er" is an ordinary word.
    static let umAndErLanguages: Set<String> = ["de", "nl", "af", "da", "nb", "nn", "no", "sv", "is", "lb", "fy", "gsw"]

    /// Whether "um" and "er" should be read as words in `text`: the user
    /// speaks one of `umAndErLanguages` (or didn't pick languages) and the
    /// dictation reads as one of them. A user who picked only other
    /// languages always gets them removed.
    static func umAndErAreWords(in text: String, languages: [String]) -> Bool {
        let codes = Set(languages.map { String($0.lowercased().split(separator: "-").first ?? "") })
        if !codes.isEmpty, codes.isDisjoint(with: umAndErLanguages) { return false }
        // Only worth asking when one of them is in the text.
        let lowered = text.lowercased()
        guard lowered.contains("um") || lowered.contains("er") else { return false }
        // Read the language from the other words: a run of English fillers
        // ("Um, so, uh") reads as German on its own.
        let content = remove(from: text)
        guard content.split(whereSeparator: \.isWhitespace).count >= 2 else { return false }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(content)
        guard let dominant = recognizer.dominantLanguage?.rawValue else { return false }
        let code = String(dominant.split(separator: "-").first ?? "")
        guard umAndErLanguages.contains(code) else { return false }
        // Norwegian Bokmål is detected as "nb"; a user may have picked "no".
        return codes.isEmpty || codes.contains(code) || (code == "nb" && codes.contains("no"))
    }

    /// Fillers that are words in some languages.
    private static let wordLikeFillers: Set<String> = ["um", "er"]

    static func remove(from text: String, keepingWordLikeFillers: Bool = false) -> String {
        let chars = Array(text)
        var out: [Character] = []
        out.reserveCapacity(chars.count)
        // A filler was just removed: the next text decides the spacing.
        var removed = false
        var capitalize = false
        var index = 0
        while index < chars.count {
            if let end = fillerEnd(in: chars, at: index, keepingWordLike: keepingWordLikeFillers) {
                TextScan.trimEnd(&out)
                if !removed {
                    capitalize = chars[index].isUppercase && TextScan.atSentenceStart(out)
                }
                index = afterFiller(chars, end)
                removed = true
                continue
            }
            let c = chars[index]
            index += 1
            if removed {
                if TextScan.isSpace(c) { continue }
                if c == "\n" {
                    removed = false
                    capitalize = false
                    out.append(c)
                    continue
                }
                if ".!?,".contains(c), TextScan.atSentenceStart(out) { continue }
                removed = false
                let closing = ".,;:!?)]}\u{201D}\u{2019}\u{2026}".contains(c)
                    || (c == "\"" && (index >= chars.count || !chars[index].isLetterOrNumber))
                if closing {
                    TextScan.trimEnd(&out, also: [","])
                    capitalize = false
                } else {
                    if TextScan.needsSpace(after: out) { out.append(" ") }
                    if capitalize {
                        capitalize = false
                        out.append(contentsOf: String(c).uppercased())
                        continue
                    }
                }
            }
            out.append(c)
        }
        if removed { TextScan.trimEnd(&out, also: [","]) }
        return String(out)
    }

    /// Where the filler starting at `start` ends, if one does.
    private static func fillerEnd(in chars: [Character], at start: Int, keepingWordLike: Bool) -> Int? {
        guard chars[start].isLetter else { return nil }
        if start > 0, joinsWord(chars[start - 1]) { return nil }
        var end = start
        while end < chars.count, chars[end].isLetter { end += 1 }
        if end < chars.count, joinsWord(chars[end]) { return nil }
        let word = String(chars[start..<end])
        // Lowercase, or only the first letter capitalised ("Um", not "UM").
        let tail = word.dropFirst()
        let lowered = word.lowercased()
        guard tail == tail.lowercased(), isFiller(lowered) else { return nil }
        if keepingWordLike, wordLikeFillers.contains(lowered) { return nil }
        if isQuotedOrNamed(chars, start: start, end: end) { return nil }
        return end
    }

    /// `"um"`, `‘um’`, or "the word um": the filler is the subject, not a
    /// hesitation.
    private static func isQuotedOrNamed(_ chars: [Character], start: Int, end: Int) -> Bool {
        let quotes: Set<Character> = ["\"", "'", "`", "\u{201C}", "\u{201D}", "\u{2018}", "\u{2019}"]
        if start > 0, end < chars.count, quotes.contains(chars[start - 1]), quotes.contains(chars[end]) {
            return true
        }
        let previous = TextScan.word(before: start, in: chars)?.lowercased()
        return previous == "word" || previous == "words"
    }

    private static func joinsWord(_ c: Character) -> Bool {
        c.isLetterOrNumber || c == "-" || c == "'" || c == "\u{2019}" || c == "_"
    }

    /// Where the text continues after a filler ending at `end`, past its own
    /// comma or ellipsis.
    private static func afterFiller(_ chars: [Character], _ end: Int) -> Int {
        var index = TextScan.skipSpaces(chars, from: end)
        if index < chars.count {
            if chars[index] == "," || chars[index] == "\u{2026}" {
                index += 1
            } else if chars[index] == ".", index + 2 < chars.count, chars[index + 1] == ".", chars[index + 2] == "." {
                index += 3
            }
        }
        return TextScan.skipSpaces(chars, from: index)
    }
}

// MARK: - Spoken quotes

/// Spoken quotation marks: "open quote … close quote", "quote … end quote",
/// "quote … unquote" (and "begin quote", "end of quote", "close quotes")
/// become “…”, or "…" in code apps.
///
/// Only a complete pair converts, on one line, with words between: "quote"
/// is also a price estimate ("send me the quote for the kitchen"), so an
/// opener without its closer is left as words. A bare "quote" right after an
/// article or demonstrative ("the quote", "a quote") never opens one, and the
/// idiom "quote unquote" (nothing between) stays as said. The commas and
/// spaces a speech engine puts around the words go with them. A closer right
/// after an article ("the end quote") is a noun too.
enum SpokenQuotes {
    enum Style: String, Equatable {
        case curly
        case straight

        var open: Character { self == .curly ? "\u{201C}" : "\"" }
        var close: Character { self == .curly ? "\u{201D}" : "\"" }
    }

    private enum Kind {
        case open
        /// "quote" alone, which needs a closer to mean anything.
        case bareOpen
        case close
    }

    /// Longest first, so "end quote" is never read as "quote".
    private static let phrases: [([String], Kind)] = [
        (["end", "of", "quote"], .close),
        (["open", "quotes"], .open),
        (["open", "quote"], .open),
        (["begin", "quote"], .open),
        (["close", "quotes"], .close),
        (["close", "quote"], .close),
        (["end", "quotes"], .close),
        (["end", "quote"], .close),
        (["unquote"], .close),
        (["quote"], .bareOpen),
    ]

    private struct Match {
        let start: Int
        let end: Int
        let kind: Kind
    }

    static func apply(to text: String, style: Style) -> String {
        let chars = Array(text)
        let pairs = findPairs(in: chars)
        guard !pairs.isEmpty else { return text }
        var opens: [Int: Int] = [:]
        var closes: [Int: Int] = [:]
        for (open, close) in pairs {
            opens[open.start] = open.end
            closes[close.start] = close.end
        }
        var out: [Character] = []
        var index = 0
        while index < chars.count {
            if let end = opens[index] {
                TextScan.trimEnd(&out)
                if let last = out.last, !"\n([{\u{201C}\u{2018}\"".contains(last) {
                    out.append(" ")
                }
                out.append(style.open)
                index = skip(chars, from: end, also: ",:")
                continue
            }
            if let end = closes[index] {
                TextScan.trimEnd(&out, also: [","])
                out.append(style.close)
                index = TextScan.skipSpaces(chars, from: end)
                if index < chars.count, chars[index].isLetterOrNumber {
                    out.append(" ")
                }
                continue
            }
            out.append(chars[index])
            index += 1
        }
        return String(out)
    }

    private static func findPairs(in chars: [Character]) -> [(Match, Match)] {
        var matches: [Match] = []
        var index = 0
        while index < chars.count {
            if TextScan.isWordStart(chars, index), let match = phrase(at: index, in: chars) {
                matches.append(match)
                index = match.end
                continue
            }
            index += 1
        }
        var pairs: [(Match, Match)] = []
        var pending: Match?
        for match in matches {
            switch match.kind {
            case .open, .bareOpen:
                // A second opener drops an earlier one that never closed.
                pending = match
            case .close:
                guard let open = pending else { continue }
                pending = nil
                let between = chars[open.end..<match.start]
                guard !between.contains("\n"), between.contains(where: \.isLetterOrNumber) else { continue }
                pairs.append((open, match))
            }
        }
        return pairs
    }

    private static func phrase(at start: Int, in chars: [Character]) -> Match? {
        for (words, kind) in phrases {
            guard let end = TextScan.matchWords(words, in: chars, at: start) else { continue }
            // "the quote", "the end quote": a noun, not a quotation mark.
            if kind != .open, let previous = TextScan.word(before: start, in: chars)?.lowercased(),
               TextScan.determiners.contains(previous) {
                return nil
            }
            return Match(start: start, end: end, kind: kind)
        }
        return nil
    }

    private static func skip(_ chars: [Character], from start: Int, also: String) -> Int {
        var index = start
        while index < chars.count, TextScan.isSpace(chars[index]) || also.contains(chars[index]) {
            index += 1
        }
        return index
    }
}

// MARK: - Spoken symbols

/// Spoken symbols joined to their words: "hashtag release" is "#release",
/// "at sign home" is "@home", "my underscore variable" is "my_variable",
/// "dash dash force" is "--force", and inside a flag "--save dash dev" is
/// "--save-dev".
///
/// Ported from Hex's Labs "Spoken symbols" (MIT), narrowed to the symbols
/// whose names are rarely prose. Left out on purpose: "comma", "colon",
/// "period" (cleanup's prompt handles those as commands vs named words),
/// "slash", "hyphen" and "dash" outside a flag ("a slash command", "use a
/// hyphen", "a dash of salt").
///
/// A symbol only joins when it is said as one:
/// - the next word follows after spaces only (no punctuation between) and is
///   a content word: "the hashtag is trending" and "hashtag and" stay;
/// - the word before isn't an article, demonstrative or quantifier ("the
///   hashtag", "an underscore", "one at sign"); for "#", "@" and "--" also
///   not a possessive ("your hashtag game");
/// - "underscore" also needs a word right before it ("my underscore
///   variable"), since it joins both sides.
///
/// Matching ignores case and needs whole words, so "hashtags" or
/// "underscored" stay.
enum SpokenSymbols {
    private enum Join {
        /// Joins the next word: "#release".
        case next
        /// Joins both words: "my_variable".
        case both
        /// Joins both words, but only inside a command-line flag the
        /// dictation already started: "--save dash dev" is "--save-dev".
        case insideFlag
    }

    private static let symbols: [([String], String, Join)] = [
        (["hashtag"], "#", .next),
        (["hash", "tag"], "#", .next),
        (["hash", "sign"], "#", .next),
        (["at", "sign"], "@", .next),
        (["underscore"], "_", .both),
        (["dash", "dash"], "--", .next),
        (["double", "dash"], "--", .next),
        (["dash"], "-", .insideFlag),
    ]

    /// Words after which a symbol name is a noun: "the hashtag", "an
    /// underscore".
    private static let possessives: Set<String> = ["my", "your", "our", "their", "his", "her", "its", "whose"]

    /// Words that can't be the thing a symbol attaches to.
    private static let stopwordsAfter: Set<String> = [
        "is", "was", "are", "were", "be", "been", "being", "and", "or", "but", "nor", "so", "then",
        "the", "a", "an", "to", "of", "in", "on", "at", "for", "with", "from", "by", "as", "into",
        "that", "this", "these", "those", "it", "its", "here", "there", "between", "instead", "too",
        "key", "keys", "sign", "signs", "symbol", "symbols", "character", "characters", "button",
        "has", "had", "have", "will", "would", "can", "could", "should", "might", "must",
        "isn't", "wasn't", "doesn't", "don't", "didn't",
    ]

    static func apply(to text: String) -> String {
        let chars = Array(text)
        var out: [Character] = []
        out.reserveCapacity(chars.count)
        var index = 0
        while index < chars.count {
            if TextScan.isWordStart(chars, index), let (symbol, next, joinsBefore) = symbol(at: index, in: chars, out: out) {
                if joinsBefore { TextScan.trimEnd(&out) }
                out.append(contentsOf: symbol)
                index = next
                continue
            }
            out.append(chars[index])
            index += 1
        }
        return String(out)
    }

    /// The symbol said at `start`, where the text continues after it, and
    /// whether it joins the word before, when it is said as a symbol.
    private static func symbol(at start: Int, in chars: [Character], out: [Character]) -> (String, Int, Bool)? {
        for (words, symbol, join) in symbols {
            guard let end = TextScan.matchWords(words, in: chars, at: start) else { continue }
            // Spaces only, then a content word.
            let next = TextScan.skipSpaces(chars, from: end)
            guard next > end, next < chars.count, chars[next].isLetterOrNumber else { return nil }
            if let nextWord = TextScan.word(at: next, in: chars)?.lowercased(), stopwordsAfter.contains(nextWord) {
                return nil
            }
            let previous = TextScan.word(before: out.count, in: out)?.lowercased()
            if let previous, TextScan.determiners.contains(previous) { return nil }
            switch join {
            case .next:
                if let previous, possessives.contains(previous) { return nil }
                return (symbol, next, false)
            case .insideFlag:
                var trimmed = out
                TextScan.trimEnd(&trimmed)
                guard trimmed.count < out.count, let last = trimmed.last, last.isLetterOrNumber else { return nil }
                var tokenStart = trimmed.count
                while tokenStart > 0, !trimmed[tokenStart - 1].isWhitespace { tokenStart -= 1 }
                guard trimmed[tokenStart] == "-" else { return nil }
                return (symbol, next, true)
            case .both:
                // A word right before, after spaces only.
                var trimmed = out
                TextScan.trimEnd(&trimmed)
                guard trimmed.count < out.count, let last = trimmed.last, last.isLetterOrNumber else { return nil }
                return (symbol, next, true)
            }
        }
        return nil
    }
}

// MARK: - Shared scanning helpers

enum TextScan {
    /// Articles, demonstratives and quantifiers: after one, a symbol or
    /// quote name is a noun.
    static let determiners: Set<String> = [
        "a", "an", "the", "this", "that", "these", "those", "no", "any", "each", "every", "another",
        "one", "some", "single", "double", "extra", "which", "what",
    ]

    static func isSpace(_ c: Character) -> Bool {
        c == " " || c == "\t" || c == "\u{00A0}"
    }

    static func isWordStart(_ chars: [Character], _ index: Int) -> Bool {
        guard chars[index].isLetterOrNumber else { return false }
        return index == 0 || !(chars[index - 1].isLetterOrNumber || chars[index - 1] == "_")
    }

    static func skipSpaces(_ chars: [Character], from start: Int) -> Int {
        var index = start
        while index < chars.count, isSpace(chars[index]) { index += 1 }
        return index
    }

    static func trimEnd(_ out: inout [Character], also: Set<Character> = []) {
        while let last = out.last, isSpace(last) || also.contains(last) {
            out.removeLast()
        }
    }

    static func atSentenceStart(_ out: [Character]) -> Bool {
        guard let last = out.last else { return true }
        return ".!?\n".contains(last)
    }

    static func needsSpace(after out: [Character]) -> Bool {
        guard let last = out.last else { return false }
        switch last {
        case "\n", "(", "[", "{", "\u{201C}", "\u{2018}":
            return false
        case "\"":
            return out.count >= 2 && !out[out.count - 2].isWhitespace
        default:
            return true
        }
    }

    /// Matches `words` (lowercase ASCII) at `start`, separated by spaces,
    /// ignoring case, ending at a word boundary. Returns the end index.
    static func matchWords(_ words: [String], in chars: [Character], at start: Int) -> Int? {
        var position = start
        for (number, word) in words.enumerated() {
            if number > 0 {
                let after = skipSpaces(chars, from: position)
                guard after > position else { return nil }
                position = after
            }
            for expected in word {
                guard position < chars.count, chars[position].lowercased() == String(expected) else { return nil }
                position += 1
            }
        }
        if position < chars.count, chars[position].isLetterOrNumber || chars[position] == "_" { return nil }
        return position
    }

    /// The word (letters, digits, apostrophes) starting at `index`.
    static func word(at index: Int, in chars: [Character]) -> String? {
        var end = index
        while end < chars.count, chars[end].isLetterOrNumber || chars[end] == "'" || chars[end] == "\u{2019}" { end += 1 }
        return end > index ? String(chars[index..<end]).replacingOccurrences(of: "\u{2019}", with: "'") : nil
    }

    /// The word just before `index`, past spaces only.
    static func word(before index: Int, in chars: [Character]) -> String? {
        var end = index
        while end > 0, isSpace(chars[end - 1]) { end -= 1 }
        var start = end
        while start > 0, chars[start - 1].isLetterOrNumber || chars[start - 1] == "'" || chars[start - 1] == "\u{2019}" { start -= 1 }
        return start < end ? String(chars[start..<end]).replacingOccurrences(of: "\u{2019}", with: "'") : nil
    }
}

extension Character {
    var isLetterOrNumber: Bool { isLetter || isNumber }
}
