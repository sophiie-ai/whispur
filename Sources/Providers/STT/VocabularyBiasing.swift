import Foundation

/// Builds a Whisper `prompt` string from the user's custom vocabulary.
///
/// Whisper biases decoding toward words that appear in the prompt, but the
/// prompt is capped at 224 tokens, so we format the terms as a brief
/// comma-separated list rather than verbose sentences.
enum WhisperVocabularyPrompt {
    /// ~224-token budget → keep well below a few hundred chars of ASCII text.
    private static let maxCharacterCount = 800

    static func build(from vocabulary: [String]) -> String? {
        let terms = vocabulary
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else { return nil }

        var result = ""
        for term in terms {
            let addition = result.isEmpty ? term : ", " + term
            if result.count + addition.count > maxCharacterCount {
                break
            }
            result += addition
        }
        return result.isEmpty ? nil : result
    }
}

/// Parses the user's vocabulary blob (one term per line or comma-separated)
/// into a deduplicated list of non-empty trimmed terms.
enum VocabularyParser {
    static func parse(_ raw: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for chunk in raw.split(whereSeparator: { $0.isNewline || $0 == "," }) {
            let term = chunk.trimmingCharacters(in: .whitespaces)
            guard !term.isEmpty else { continue }
            let key = term.lowercased()
            if seen.insert(key).inserted {
                result.append(term)
            }
        }
        return result
    }
}
