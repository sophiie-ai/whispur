import Foundation

/// Builds the user message for a cleanup request.
///
/// The system prompt stays fixed (cache-friendly); everything that varies per
/// dictation goes here, as delimited data:
///
///     <vocabulary>            (only when the user has terms)
///     Claude Code
///     Sophiie (heard as: Sophie)
///     </vocabulary>
///     Write a term for its "heard as" word when …   (only with heard-as hints)
///
///     <dictation-to-clean>
///     …transcript…
///     </dictation-to-clean>
///
///     Output only the cleaned text of the dictation above, …
///
/// `scripts/eval-cleanup.py` mirrors this format; both are checked against
/// `Evals/cleanup/golden/user-message.txt`.
enum CleanupMessage {
    static let transcriptTag = "dictation-to-clean"
    static let vocabularyTag = "vocabulary"

    /// - Parameter heardAs: Term -> spellings a transcript may show instead,
    ///   when they are ordinary words Whispur doesn't replace in code
    ///   (`VocabularyAliasPlan.heardAs`). Shown after the term: "Whispur
    ///   (heard as: Whisper)", so the model replaces them when the context
    ///   fits and keeps them when they are meant as written.
    static func userMessage(transcript: String, vocabulary: [String], heardAs: [String: [String]] = [:]) -> String {
        var sections: [String] = []

        let terms = vocabularyLines(vocabulary, heardAs: heardAs)
        if !terms.isEmpty {
            var block = "<\(vocabularyTag)>\n\(terms.joined(separator: "\n"))\n</\(vocabularyTag)>"
            if terms != vocabularyTerms(vocabulary) { block += "\n" + heardAsNote }
            sections.append(block)
        }

        sections.append("<\(transcriptTag)>\n\(neutralizeTags(transcript))\n</\(transcriptTag)>")
        sections.append(Prompts.cleanupOutputContract)
        return sections.joined(separator: "\n\n")
    }

    /// One term per line: trimmed, inner line breaks collapsed to spaces,
    /// empty terms dropped, tag look-alikes neutralized.
    static func vocabularyTerms(_ vocabulary: [String]) -> [String] {
        vocabulary
            .map { term in
                term.components(separatedBy: .newlines)
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
            .map(neutralizeTags)
    }

    /// Follows the vocabulary block when a term carries "heard as" hints.
    /// Without it the hints read as "always replace": on the eval's guard
    /// set ("Sophie from accounting called") the model wrote the term in
    /// 10 of 12 runs; with it, 2 of 12, at the same recall.
    static let heardAsNote = """
        Write a term for its "heard as" word when the sentence is about that term; \
        keep the word when it means a person, another product, or its ordinary sense.
        """

    /// `vocabularyTerms`, each followed by its "heard as" spellings.
    static func vocabularyLines(_ vocabulary: [String], heardAs: [String: [String]]) -> [String] {
        let hints = Dictionary(
            heardAs.map { (vocabularyTerms([$0.key]).first ?? "", vocabularyTerms($0.value)) },
            uniquingKeysWith: +
        )
        return vocabularyTerms(vocabulary).map { term in
            guard let aliases = hints[term], !aliases.isEmpty else { return term }
            return "\(term) (heard as: \(aliases.joined(separator: ", ")))"
        }
    }

    private static let tagPattern = try! NSRegularExpression(
        pattern: "<(\\s*/?\\s*)(\(transcriptTag)|\(vocabularyTag))",
        options: [.caseInsensitive]
    )

    /// Breaks any opening or closing look-alike of the message's own tags
    /// (any case, any spacing) by inserting a zero-width space after `<`, so
    /// dictated or vocabulary text can't close its block early or open a new
    /// one. All other text, including other `<…>` content, is left as is.
    static func neutralizeTags(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return tagPattern.stringByReplacingMatches(in: text, range: range, withTemplate: "<\u{200B}$1$2")
    }
}
