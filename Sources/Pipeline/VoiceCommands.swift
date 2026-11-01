import Foundation

/// Spoken editing commands applied in code, before LLM cleanup.
///
/// - "scratch that" / "delete that" removes the sentence before it (the
///   whole dictation when that was the only one).
/// - "new line" / "newline" becomes a line break, "new paragraph" a blank
///   line.
///
/// They run on the raw transcript, not on the cleanup, so the model never
/// sees the words a "scratch that" deleted and can't bring them back, and the
/// raw-transcript fallback (cleanup skipped or failed) gets them too.
/// `restoreLineBreaks` then puts the inserted breaks back if the model
/// reflowed them.
///
/// A command only fires when it is said as a command:
/// - standalone: punctuation or the start of the text before it, and
///   punctuation or the end after it ("Send it to Alice. Scratch that."), or
/// - sentence-final after a word that doesn't make it part of the sentence
///   ("send it to Alice scratch that." fires; "we should delete that." and
///   "we need a new line." don't).
/// Mid-phrase uses ("a new line of products", "she said scratch that and
/// left") are never touched. Unpunctuated mid-stream commands are left to
/// the cleanup prompt, which handles spoken "new line" too.
enum VoiceCommands {
    private enum Command {
        case scratch
        case lineBreak(String)
    }

    private static let pattern = try! NSRegularExpression(
        pattern: "\\b(scratch that|delete that|new ?line|new paragraph)\\b",
        options: [.caseInsensitive]
    )

    /// Punctuation that can stand right before or after a command.
    private static let boundaryPunctuation = Set(".!?,;:")
    private static let sentenceEnd = Set(".!?\n")

    /// Words that, said right before a sentence-final command, make the
    /// command words part of the sentence ("please delete that", "add a new
    /// line", "she said scratch that").
    private static let leadIns: Set<String> = [
        "a", "an", "the", "this", "that", "these", "those", "another", "any", "each", "every", "no",
        "one", "some", "our", "your", "my", "their", "his", "her", "its", "whose",
        "i", "you", "we", "they", "he", "she", "it", "i'll", "you'll", "we'll", "they'll", "he'll",
        "she'll", "i'd", "you'd", "we'd", "they'd", "let's", "lets",
        "can", "could", "will", "would", "should", "shall", "must", "might", "may", "do", "does",
        "did", "don't", "doesn't", "didn't", "won't", "wouldn't", "can't", "cannot", "shouldn't",
        "to", "gonna", "wanna", "please", "just", "not", "never", "also", "then", "and", "or", "but",
        "said", "say", "says", "saying", "told", "tell", "type", "typed", "write", "wrote", "word",
        "words", "phrase", "called", "add", "insert", "start", "begin", "need", "needs", "want",
        "wants", "use", "make", "with", "of", "for", "on", "in", "at", "by", "from", "into", "about",
        "like", "as", "is", "was", "are", "were", "be", "been",
    ]

    /// Words that carry no content of their own before a "scratch that"
    /// ("oh sorry, scratch that"): they go with the command, and the
    /// sentence before them is the one removed.
    private static let preambleWords: Set<String> = [
        "oh", "oops", "um", "uh", "hmm", "okay", "ok", "wait", "no", "sorry", "actually", "so",
        "well", "yeah", "nah", "nope",
    ]

    /// The transcript with every spoken command applied. Empty when a
    /// "scratch that" removed everything.
    static func apply(to transcript: String) -> String {
        var text = transcript
        var searchFrom = text.startIndex
        while let (range, command) = nextCommand(in: text, from: searchFrom) {
            let prefix = String(text[..<range.lowerBound])
            let suffix = String(text[range.upperBound...])
            let replaced: (kept: String, rest: String)
            switch command {
            case .scratch:
                replaced = (removingLastSentence(of: prefix), leadingTrimmed(suffix))
            case let .lineBreak(separator):
                let kept = trailingTrimmed(prefix, extra: ",;:")
                replaced = (kept.isEmpty ? "" : kept + separator, leadingTrimmed(suffix))
            }
            let rest = capitalizingFirst(replaced.rest)
            let joiner = replaced.kept.isEmpty || replaced.kept.hasSuffix("\n") || rest.isEmpty ? "" : " "
            let head = replaced.kept + joiner
            text = head + rest
            searchFrom = text.index(text.startIndex, offsetBy: head.count)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Puts the transcript's line breaks back into the cleanup when the model
    /// kept the same blocks but changed the breaks between them (a blank line
    /// collapsed to one break, say). Returns `cleaned` unchanged when the
    /// transcript has no line breaks or the block counts differ (the model
    /// built a list or merged lines).
    static func restoreLineBreaks(in cleaned: String, from transcript: String) -> String {
        guard transcript.contains("\n") else { return cleaned }
        let source = blocks(of: transcript)
        let target = blocks(of: cleaned)
        guard source.blocks.count == target.blocks.count, source.blocks.count > 1 else { return cleaned }
        var result = target.blocks[0]
        for (separator, block) in zip(source.separators, target.blocks.dropFirst()) {
            result += separator + block
        }
        return result
    }

    // MARK: - Matching

    private static func nextCommand(in text: String, from start: String.Index) -> (Range<String.Index>, Command)? {
        let nsRange = NSRange(start..., in: text)
        for match in pattern.matches(in: text, range: nsRange) {
            guard let range = Range(match.range, in: text) else { continue }
            let phrase = text[range].lowercased()
            let command: Command
            if phrase.hasPrefix("new paragraph") {
                command = .lineBreak("\n\n")
            } else if phrase.hasPrefix("new") {
                command = .lineBreak("\n")
            } else {
                command = .scratch
            }
            if isCommand(command, at: range, in: text) {
                return (range, command)
            }
        }
        return nil
    }

    private static func isCommand(_ command: Command, at range: Range<String.Index>, in text: String) -> Bool {
        // After: punctuation or the end.
        let after = text[range.upperBound...].drop { $0 == " " || $0 == "\t" }
        guard after.first.map({ boundaryPunctuation.contains($0) || $0 == "\n" }) ?? true else { return false }
        let endsSentence = after.first.map { sentenceEnd.contains($0) } ?? true

        // Before: punctuation or the start, or a sentence-final command after
        // a word that leaves it outside the sentence.
        let before = text[..<range.lowerBound].reversed().drop { $0 == " " || $0 == "\t" }
        let leftIsBoundary = before.first.map { boundaryPunctuation.contains($0) || $0 == "\n" } ?? true
        if case .scratch = command {
            // Nothing before it: nothing to scratch, so the words are content.
            let prefix = text[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            if words(in: prefix).allSatisfy(preambleWords.contains) { return false }
        }
        if leftIsBoundary { return true }
        guard endsSentence else { return false }
        let leftWord = String(before.prefix { $0.isLetter || $0 == "'" || $0 == "\u{2019}" }.reversed())
            .lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        if case .scratch = command, preambleWords.contains(leftWord) { return true }
        return !leftWord.isEmpty && !leadIns.contains(leftWord)
    }

    // MARK: - Editing

    /// `prefix` without its last sentence: the words of the current sentence
    /// before the command, or, when there are none (or only "oh sorry"), the
    /// sentence before that.
    private static func removingLastSentence(of prefix: String) -> String {
        var text = trailingTrimmed(prefix, extra: ",;:")
        let fragmentStart = lastSentenceStart(in: text)
        let fragment = String(text[fragmentStart...])
        let fragmentWords = words(in: fragment)
        text = String(text[..<fragmentStart])
        if fragmentWords.isEmpty || fragmentWords.allSatisfy(preambleWords.contains) {
            text = trailingTrimmed(text, extra: ".!?")
            text = String(text[..<lastSentenceStart(in: text)])
        }
        return trailingTrimmed(text, extra: "")
    }

    /// Index just after the last sentence end (or line break) in `text`.
    private static func lastSentenceStart(in text: String) -> String.Index {
        guard let end = text.lastIndex(where: { sentenceEnd.contains($0) }) else { return text.startIndex }
        return text.index(after: end)
    }

    private static func words(in text: String) -> [String] {
        text.lowercased()
            .split { !($0.isLetter || $0.isNumber || $0 == "'") }
            .map(String.init)
    }

    private static func trailingTrimmed(_ text: String, extra: String) -> String {
        let strip = Set(extra)
        var text = Substring(text)
        while let last = text.last, last == " " || last == "\t" || strip.contains(last) {
            text = text.dropLast()
        }
        return String(text)
    }

    private static func leadingTrimmed(_ text: String) -> String {
        String(text.drop { $0.isWhitespace || boundaryPunctuation.contains($0) })
    }

    private static func capitalizingFirst(_ text: String) -> String {
        guard let first = text.first, first.isLowercase else { return text }
        return first.uppercased() + text.dropFirst()
    }

    private static func blocks(of text: String) -> (blocks: [String], separators: [String]) {
        var blocks: [String] = []
        var separators: [String] = []
        var newlines = 0
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                newlines += 1
                continue
            }
            if !blocks.isEmpty {
                separators.append(newlines > 1 ? "\n\n" : "\n")
            }
            blocks.append(trimmed)
            newlines = 1
        }
        return (blocks, separators)
    }
}
