import Foundation

/// Builds the user message for a cleanup request.
///
/// The system prompt stays fixed (cache-friendly); everything that varies per
/// dictation goes here, as delimited data:
///
///     <vocabulary>            (only when the user has terms)
///     Claude Code
///     Sophiie
///     </vocabulary>
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

    static func userMessage(transcript: String, vocabulary: [String]) -> String {
        var sections: [String] = []

        let terms = vocabularyTerms(vocabulary)
        if !terms.isEmpty {
            sections.append("<\(vocabularyTag)>\n\(terms.joined(separator: "\n"))\n</\(vocabularyTag)>")
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
