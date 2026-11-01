import Foundation
import os

private let logger = Logger(subsystem: "ai.sophiie.whispur", category: "ScriptGuard")

/// Batch transcription for users who speak several languages.
///
/// The first request goes out as usual: every language for providers that
/// take several, auto-detect for the rest. When the transcript comes back in
/// a script none of the user's languages use (Whisper hearing a short
/// Spanish clip as Arabic), the recording is transcribed again once per
/// language, forced, in parallel, and the best of those wins.
enum MultiLanguageTranscription {
    /// What the guard did, for the Requests log.
    struct GuardReport: Equatable {
        let provider: STTProviderID
        /// The transcript that failed the check.
        let rejected: String
        let check: ScriptGuard.Check
        /// One entry per forced re-run, in the order of the user's languages.
        let attempts: [Attempt]
        /// The ISO code whose re-run was kept, or nil when every re-run failed
        /// and the original was kept.
        let chosenLanguage: String?
        let chosenText: String

        struct Attempt: Equatable {
            let language: String
            let text: String?
            let confidence: Double?
            let error: String?
        }
    }

    /// Cap on forced re-runs, so a long language list can't fan out into
    /// many paid requests for one dictation.
    static let maxForcedRuns = 4

    /// Transcribes `fileURL`, re-running per language when the script guard
    /// fires. `initial` skips the first request: a streamed transcript that
    /// already failed the guard.
    static func transcribe(
        provider: any STTProvider,
        providerID: STTProviderID,
        fileURL: URL,
        language: STTLanguageSelection,
        vocabulary: [String],
        initial: String? = nil,
        onGuard: (GuardReport) -> Void = { _ in }
    ) async throws -> String {
        let first: String
        if let initial {
            first = initial
        } else {
            first = try await provider.transcribe(fileURL: fileURL, language: language, vocabulary: vocabulary)
        }
        guard let check = ScriptGuard.check(first, for: language), check.fails else { return first }

        let scripts = check.unexpectedScripts.map(\.rawValue).sorted().joined(separator: ", ")
        logger.warning("\(providerID.rawValue, privacy: .public) transcript used \(scripts, privacy: .public); re-running per language")

        let languages = Array(language.isoCodes.prefix(maxForcedRuns))
        let attempts = await withTaskGroup(of: (Int, GuardReport.Attempt).self) { group in
            for (index, iso) in languages.enumerated() {
                group.addTask {
                    do {
                        let scored = try await provider.transcribeScored(
                            fileURL: fileURL,
                            language: language.forcing(iso: iso),
                            vocabulary: vocabulary
                        )
                        return (index, .init(language: iso, text: scored.text, confidence: scored.confidence, error: nil))
                    } catch {
                        return (index, .init(language: iso, text: nil, confidence: nil, error: error.localizedDescription))
                    }
                }
            }
            var results: [(Int, GuardReport.Attempt)] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }

        let chosen = pick(attempts, for: language)
        let report = GuardReport(
            provider: providerID,
            rejected: first,
            check: check,
            attempts: attempts,
            chosenLanguage: chosen?.language,
            chosenText: chosen?.text ?? first
        )
        onGuard(report)
        return report.chosenText
    }

    /// The re-run to keep. Re-runs that errored or came back empty are out.
    /// Ones that pass the script check beat ones that don't. Among those,
    /// when every candidate has a confidence the most confident wins;
    /// otherwise the one with the fewest out-of-script letters, then the
    /// longest. Nil when no re-run produced text.
    static func pick(_ attempts: [GuardReport.Attempt], for language: STTLanguageSelection) -> GuardReport.Attempt? {
        let candidates = attempts.filter { !($0.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !candidates.isEmpty else { return nil }

        func check(_ attempt: GuardReport.Attempt) -> ScriptGuard.Check? {
            ScriptGuard.check(attempt.text ?? "", for: language)
        }
        let passing = candidates.filter { !(check($0)?.fails ?? false) }
        let pool = passing.isEmpty ? candidates : passing

        if pool.allSatisfy({ $0.confidence != nil }) {
            return pool.max { ($0.confidence ?? 0) < ($1.confidence ?? 0) }
        }
        return pool.min { lhs, rhs in
            let left = check(lhs)?.unexpectedLetters ?? 0
            let right = check(rhs)?.unexpectedLetters ?? 0
            if left != right { return left < right }
            return (lhs.text ?? "").count > (rhs.text ?? "").count
        }
    }

    /// One readable block for the Requests log.
    static func logSummary(_ report: GuardReport) -> String {
        var lines = [
            "Script guard: the transcript used \(report.check.unexpectedScripts.map(\.rawValue).sorted().joined(separator: ", ")) letters (\(report.check.unexpectedLetters) of \(report.check.totalLetters)), which none of your languages use.",
            "Rejected: \(report.rejected)",
            "Re-ran once per language:",
        ]
        for attempt in report.attempts {
            let confidence = attempt.confidence.map { String(format: " (avg logprob %.2f)", $0) } ?? ""
            if let error = attempt.error {
                lines.append("  \(attempt.language): failed: \(error)")
            } else {
                lines.append("  \(attempt.language)\(confidence): \(attempt.text ?? "")")
            }
        }
        lines.append(report.chosenLanguage.map { "Kept: \($0)" } ?? "Kept: the original (every re-run failed)")
        return lines.joined(separator: "\n")
    }
}
