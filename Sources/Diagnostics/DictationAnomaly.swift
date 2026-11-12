import Foundation

/// Decides when a dictation looks wrong enough to keep its recording.
///
/// Successful recordings are not kept. An anomalous one is, under the same
/// rules as a failed one (`FailedAudioStore`: this Mac only, owner-only,
/// out of backups, deleted after 24 hours), so it can be replayed or
/// transcribed again from Activity.
enum DictationAnomaly {
    enum Reason: String, Codable, CaseIterable, Equatable {
        /// An error ended the dictation.
        case failed
        /// Long audio produced very little text: the transcript likely
        /// dropped speech.
        case lowCharacterRate
        /// Cleanup replaced most of the words instead of tidying them.
        case cleanupDiverged
        /// The selected speech provider didn't produce the transcript (its
        /// model wasn't downloaded, or a stream fell back to a batch request).
        case sttFellBack
        /// Long audio ended with no speech: the speech gate found none, the
        /// transcript was empty, or nothing was left after spoken edits.
        case noSpeech

        var label: String {
            switch self {
            case .failed: "Failed"
            case .lowCharacterRate: "Few words for the audio length"
            case .cleanupDiverged: "Cleanup changed most of the words"
            case .sttFellBack: "Speech provider fell back"
            case .noSpeech: "No speech"
            }
        }
    }

    /// Audio shorter than this is never judged on its character rate, and a
    /// no-speech result from it is never anomalous: a short pause before a
    /// short phrase, or an accidental tap, is normal.
    static let minSecondsForRate: Double = 10
    /// Characters per second below which long audio counts as anomalous.
    /// Speech runs at roughly 12-15 characters per second, so 3 means most
    /// of the recording produced no text.
    static let minCharactersPerSecond: Double = 3
    /// Cleanup edit divergence above which cleanup counts as anomalous
    /// (more than half the words changed after ignoring case and
    /// punctuation; ordinary cleanup changes fillers and a few words).
    static let maxCleanupDivergence: Double = 0.5
    /// Transcripts shorter than this are never judged on divergence: one
    /// changed word in a three-word phrase is already 33%.
    static let minWordsForDivergence = 8

    /// Why `diagnostics` looks wrong, or empty when it looks normal.
    /// Cancelled dictations are never anomalous; no-speech ones are when the
    /// audio was at least `minSecondsForRate` long.
    static func reasons(for diagnostics: DictationDiagnostics) -> [Reason] {
        switch diagnostics.outcome {
        case .cancelled:
            return []
        case .noSpeech:
            guard let seconds = diagnostics.audio?.recordingSeconds, seconds >= minSecondsForRate else { return [] }
            return [.noSpeech]
        case .failed:
            return [.failed]
        case .success:
            break
        }
        var reasons: [Reason] = []
        if let audio = diagnostics.audio,
           audio.recordingSeconds >= minSecondsForRate,
           let cps = diagnostics.transcription?.charactersPerSecond,
           cps < minCharactersPerSecond {
            reasons.append(.lowCharacterRate)
        }
        if let divergence = diagnostics.cleanup?.editDivergence,
           (diagnostics.transcription?.rawWordCount ?? 0) >= minWordsForDivergence,
           divergence > maxCleanupDivergence {
            reasons.append(.cleanupDiverged)
        }
        if let transcription = diagnostics.transcription,
           transcription.fallbackFrom != nil || transcription.streamFellBack {
            reasons.append(.sttFellBack)
        }
        return reasons
    }
}

/// Marks a history entry whose dictation looked wrong, and where its
/// recording is kept.
struct DictationAnomalyMark: Codable, Equatable {
    var reasons: [DictationAnomaly.Reason]
    /// File name in `FailedAudioStore`, or nil once deleted or expired.
    var audioFileName: String?
    /// Length of the recording, for the no-speech reason's wording.
    var audioSeconds: Double?

    var summary: String {
        reasons.map { reason in
            if reason == .noSpeech, let audioSeconds {
                return "No speech in \(Int(audioSeconds.rounded())) s of audio"
            }
            return reason.label
        }.joined(separator: " · ")
    }
}
