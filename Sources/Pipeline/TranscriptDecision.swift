import Foundation

/// Pure decisions about what (if anything) gets pasted after STT and cleanup.
/// Kept free of pipeline state so each rule can be tested directly.
enum TranscriptDecision {
    /// What the pipeline does with a finished dictation.
    enum Outcome: Equatable {
        /// Paste `text`. `reason` says why the raw transcript was used
        /// instead of the cleanup, or is nil when the cleanup was pasted.
        case paste(String, rawFallbackReason: RawFallbackReason?)
        /// Nothing worth pasting: the transcript itself was not speech.
        case dismiss
    }

    enum RawFallbackReason: String, Equatable {
        /// Cleanup was skipped, unavailable, or failed (error, truncation, refusal).
        case cleanupUnavailable = "cleanup unavailable or failed"
        /// Cleanup came back empty, "EMPTY", or as a silence phrase while the
        /// raw transcript was real speech.
        case cleanupEmpty = "cleanup returned no text for real speech"
        /// Cleanup answered the dictation instead of cleaning it.
        case assistantReply = "cleanup looks like an assistant reply"
    }

    /// The trimmed raw transcript, or nil when the STT output is not speech
    /// (empty, the "EMPTY" sentinel, only bracketed non-speech annotations,
    /// or a known silence hallucination).
    static func normalizedRawTranscript(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.uppercased() != "EMPTY" else { return nil }
        if isOnlyNonSpeechAnnotations(trimmed) { return nil }
        if isKnownSilenceHallucination(trimmed) { return nil }
        return trimmed
    }

    /// Decides the final paste. `raw` must already be normalized speech
    /// (see `normalizedRawTranscript`); `cleaned` is the provider's text, or
    /// nil when cleanup didn't run or failed.
    ///
    /// Once the raw transcript is known to be speech, the dictation is never
    /// dropped: an empty, "EMPTY" or silence-phrase cleanup means the model
    /// misjudged real speech, so the raw transcript is pasted instead.
    static func finalOutcome(raw: String, cleaned: String?) -> Outcome {
        let raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedRawTranscript(raw) != nil else { return .dismiss }

        guard let cleaned else {
            return .paste(raw, rawFallbackReason: .cleanupUnavailable)
        }

        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.uppercased() == "EMPTY" || isKnownSilenceHallucination(trimmed) {
            return .paste(raw, rawFallbackReason: .cleanupEmpty)
        }

        if looksLikeAssistantResponse(cleaned: trimmed, raw: raw) {
            return .paste(raw, rawFallbackReason: .assistantReply)
        }

        return .paste(trimmed, rawFallbackReason: nil)
    }

    /// Whether a transcript is long enough to be worth cleaning. Very short
    /// transcripts ("thanks", "ok") are pasted as-is: an LLM tends to answer
    /// them rather than clean them.
    static func shouldRunCleanup(for transcript: String) -> Bool {
        guard transcript.count >= 8 else { return false }

        let wordCount = transcript.split { $0.isWhitespace }.count
        if wordCount >= 2 { return true }

        return transcript.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3040 ... 0x30FF, // Hiragana and Katakana
                 0x3400 ... 0x4DBF, // CJK Unified Ideographs Extension A
                 0x4E00 ... 0x9FFF, // CJK Unified Ideographs
                 0xF900 ... 0xFAFF, // CJK Compatibility Ideographs
                 0xFF66 ... 0xFF9F: // Halfwidth Katakana
                return true
            default:
                return false
            }
        }
    }

    // MARK: - Silence hallucinations

    /// Whisper (and other STT providers trained on subtitled video) confidently
    /// emit a small set of canned phrases when given silence or near-silence —
    /// "Thanks for watching!", "[Music]", "Subtitles by the Amara.org community".
    /// If the *entire* transcript matches one of these, treat it as silence.
    ///
    /// Entries are in the normalized form `isKnownSilenceHallucination`
    /// compares against: lowercased, punctuation removed ("amara.org" →
    /// "amaraorg", "don't" → "dont").
    ///
    /// Short replies people really say ("thanks", "thank you", "bye") are not
    /// listed: the audio voice-activity gate runs before STT, so a transcript
    /// that reaches this check came from audio that contained speech.
    static let knownSilenceHallucinations: Set<String> = [
        "thank you for watching",
        "thanks for watching",
        "thank you so much for watching",
        "thanks for watching and see you next time",
        "you",
        "please subscribe",
        "like and subscribe",
        "dont forget to subscribe",
        "thanks for listening",
        "thank you for listening",
        "subtitles by the amaraorg community",
        "music",
        "applause",
        "silence",
        "blank_audio",
        "blankaudio",
    ]

    static func isKnownSilenceHallucination(_ text: String) -> Bool {
        let lowered = text.lowercased()
        let allowed = CharacterSet.alphanumerics.union(.whitespaces).union(CharacterSet(charactersIn: "_"))
        let stripped = String(lowered.unicodeScalars.filter { allowed.contains($0) })
        let collapsed = stripped
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return false }
        return knownSilenceHallucinations.contains(collapsed)
    }

    private static let annotationPattern = try! NSRegularExpression(
        pattern: #"\[[^\]]*\]|\([^)]*\)|\{[^}]*\}|<[^>]*>|♪+"#
    )

    /// True when the transcript is only machine labels such as
    /// "[BLANK_AUDIO]", "(music playing)" or "[phone ringing]" — no words the
    /// user actually said.
    static func isOnlyNonSpeechAnnotations(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        guard annotationPattern.firstMatch(in: text, range: range) != nil else { return false }
        let remainder = annotationPattern.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        return remainder.unicodeScalars.allSatisfy {
            CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.punctuationCharacters.contains($0)
        }
    }

    // MARK: - Assistant-reply detection

    /// Sentence starters that strongly suggest the LLM answered the dictation
    /// instead of cleaning it. Matched case-insensitively against the start of
    /// the cleaned text, with the trailing space included to avoid clipping
    /// real words ("I'll" matches "i'll ", not "i'll" inside "I'll-be-there").
    private static let assistantReplyPrefixes: [String] = [
        "i will ", "i'll ", "i would ", "i'd ", "i am ", "i'm ", "i can ",
        "i can't ", "i cannot ", "i don't ", "i do not ", "i need ", "i notice ",
        "as an ai", "as a language model", "as a large language",
        "sure, ", "sure! ", "certainly", "of course",
        "here's ", "here is ", "here are ",
        "sorry, ", "apologies", "my apologies",
        "the best way ", "you can ", "you could ", "you should ",
        "to do ", "to answer ", "great question",
        "it seems", "it looks like", "it sounds like",
    ]

    /// Returns true when the cleaned text looks like an assistant reply to the
    /// transcript rather than a cleanup of it. We only fall back when the
    /// cleaned output starts with an assistant-style opener AND the raw
    /// transcript did not start the same way — otherwise legitimate dictation
    /// like "I'll send it tomorrow" would be wrongly flagged.
    static func looksLikeAssistantResponse(cleaned: String, raw: String) -> Bool {
        let normalizedCleaned = cleaned
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let normalizedRaw = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        let cleanedStarts = assistantReplyPrefixes.first { normalizedCleaned.hasPrefix($0) }
        guard let prefix = cleanedStarts else { return false }
        if normalizedRaw.hasPrefix(prefix) { return false }

        // Length sanity: an assistant reply usually expands well past the raw
        // transcript. A small overage can come from punctuation/casing fixes,
        // so require the cleaned text to be noticeably longer before treating
        // an opener match as evidence of an answer.
        let rawLength = max(normalizedRaw.count, 1)
        let ratio = Double(normalizedCleaned.count) / Double(rawLength)
        return ratio >= 1.4
    }
}
