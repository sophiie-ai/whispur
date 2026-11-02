import AppKit

/// Whether a word is an ordinary English or Spanish word or a common name,
/// by the macOS spelling dictionaries ("whisper", "Sophie", "hanks" are;
/// "Wispur", "Hanx" aren't). Decides which "heard as" spellings are safe to
/// replace in code (`VocabularyAliasPlan`).
///
/// A name counts: macOS accepts "Sophie" capitalised, so the alias is only
/// replaced when the user turns on "Always replace". Words the user taught
/// the Mac's spelling checker count too.
///
/// Uses `NSSpellChecker`, so call it on the main thread.
enum CommonWords {
    static let languages = ["en", "es"]

    private static var cache: [String: Bool] = [:]

    static func isCommon(_ word: String) -> Bool {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard !trimmed.isEmpty else { return false }
        if let cached = cache[trimmed] { return cached }
        let forms = Set([trimmed, trimmed.lowercased(), trimmed.prefix(1).uppercased() + trimmed.dropFirst().lowercased()])
        let checker = NSSpellChecker.shared
        let common = forms.contains { form in
            languages.contains { language in
                checker.checkSpelling(of: form, startingAt: 0, language: language, wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
                    .location == NSNotFound
            }
        }
        cache[trimmed] = common
        return common
    }
}
