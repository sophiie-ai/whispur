import AVFoundation
import Foundation
import os
import Speech

private let logger = Logger(subsystem: "ai.sophiie.whispur", category: "AppleSTT")

/// Apple on-device speech recognition. No API key, fully offline.
///
/// On macOS 26 and later this uses `SpeechAnalyzer` with a
/// `DictationTranscriber`, which is far more accurate than
/// `SFSpeechRecognizer`. It falls back to `SFSpeechRecognizer` on older
/// systems, for languages the new model doesn't cover, and while the
/// on-device model is still downloading.
struct AppleSTT: STTProvider {
    static let providerID: STTProviderID = .apple

    func transcribe(fileURL: URL, language: STTLanguageSelection, vocabulary: [String]) async throws -> String {
        try await Self.ensureAuthorized()

        // Both engines are locked to one locale. The resolver handles `.auto`
        // by picking the system locale (or en-US).
        let localeID = STTLanguageResolver.appleLocale(for: language)
        let contextualStrings = vocabulary
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if #available(macOS 26.0, *) {
            if let text = try await AppleSpeechAnalyzerEngine.transcribe(
                fileURL: fileURL,
                localeID: localeID,
                contextualStrings: contextualStrings
            ) {
                return text
            }
        }

        return try await Self.transcribeWithLegacyRecognizer(
            fileURL: fileURL,
            localeID: localeID,
            contextualStrings: contextualStrings
        )
    }

    private static func ensureAuthorized() async throws {
        guard SFSpeechRecognizer.authorizationStatus() != .authorized else { return }
        let granted = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        guard granted else {
            throw STTError.apiError(
                provider: .apple,
                message: "Speech recognition not authorized. Enable it in System Settings > Privacy & Security.",
                statusCode: nil
            )
        }
    }

    private static func transcribeWithLegacyRecognizer(
        fileURL: URL,
        localeID: String,
        contextualStrings: [String]
    ) async throws -> String {
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeID))

        guard let recognizer, recognizer.isAvailable else {
            throw STTError.apiError(
                provider: .apple,
                message: "Speech recognizer is not available for the selected language.",
                statusCode: nil
            )
        }

        let request = SFSpeechURLRecognitionRequest(url: fileURL)
        request.shouldReportPartialResults = false
        if !contextualStrings.isEmpty {
            request.contextualStrings = contextualStrings
        }

        return try await withCheckedThrowingContinuation { continuation in
            recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    continuation.resume(throwing: STTError.apiError(
                        provider: .apple, message: error.localizedDescription, statusCode: nil
                    ))
                } else if let result, result.isFinal {
                    continuation.resume(returning: result.bestTranscription.formattedString)
                }
            }
        }
    }
}

// MARK: - Engine choice

/// Where the on-device model for a locale stands, reduced to what the
/// engine choice needs.
enum AppleSpeechAssetState: Equatable {
    case installed
    /// Supported but not on disk yet; Whispur can ask the system for it.
    case downloadable
    /// A download is already running.
    case downloading
    case unsupported
}

enum AppleSpeechRoute: Equatable {
    /// Transcribe with SpeechAnalyzer now.
    case analyzer
    /// Ask the system for the model and wait briefly for it.
    case installThenAnalyzer
    /// Use SFSpeechRecognizer for this recording.
    case legacy
}

enum AppleSpeechEngineChoice {
    /// How long a dictation waits for the model to install before falling
    /// back. Installing a locale that is already on the system takes well
    /// under a second; a real download keeps going in the background and is
    /// used from the next dictation on.
    static let installWait: Duration = .seconds(3)

    static func route(localeSupported: Bool, assets: AppleSpeechAssetState) -> AppleSpeechRoute {
        guard localeSupported else { return .legacy }
        switch assets {
        case .installed: return .analyzer
        case .downloadable: return .installThenAnalyzer
        case .downloading, .unsupported: return .legacy
        }
    }

    /// Joins analyzer results into one transcript. Each result covers a time
    /// range and a later result for the same range replaces the earlier one,
    /// so only the newest text per range start is kept, in time order.
    static func joinedTranscript(_ results: [(start: Double, text: String)]) -> String {
        var latest: [Double: String] = [:]
        for result in results {
            latest[result.start] = result.text
        }
        return latest.keys.sorted()
            .compactMap { latest[$0]?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

// MARK: - SpeechAnalyzer

@available(macOS 26.0, *)
enum AppleSpeechAnalyzerEngine {
    /// Returns `nil` when this recording should use the legacy recognizer
    /// instead (unsupported locale, model not installed yet).
    static func transcribe(fileURL: URL, localeID: String, contextualStrings: [String]) async throws -> String? {
        guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: Locale(identifier: localeID)) else {
            logger.info("SpeechAnalyzer has no model for \(localeID, privacy: .public); using SFSpeechRecognizer")
            return nil
        }

        let transcriber = DictationTranscriber(locale: locale, preset: .longDictation)
        let assets = assetState(await AssetInventory.status(forModules: [transcriber]))

        switch AppleSpeechEngineChoice.route(localeSupported: true, assets: assets) {
        case .legacy:
            logger.info("SpeechAnalyzer model not ready (\(String(describing: assets), privacy: .public)); using SFSpeechRecognizer")
            return nil
        case .installThenAnalyzer:
            guard await installModel(for: transcriber) else { return nil }
        case .analyzer:
            break
        }

        do {
            return try await analyze(fileURL: fileURL, transcriber: transcriber, contextualStrings: contextualStrings)
        } catch {
            // A failure here is the new engine's, not the recording's: give
            // the legacy recognizer a chance before the dictation is lost.
            logger.error("SpeechAnalyzer failed, using SFSpeechRecognizer: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func analyze(
        fileURL: URL,
        transcriber: DictationTranscriber,
        contextualStrings: [String]
    ) async throws -> String {
        let context = AnalysisContext()
        if !contextualStrings.isEmpty {
            context.contextualStrings[.general] = contextualStrings
        }

        // Start reading results before analysis begins so none are missed.
        let collector = Task { () -> [(start: Double, text: String)] in
            var results: [(start: Double, text: String)] = []
            for try await result in transcriber.results {
                results.append((result.range.start.seconds, String(result.text.characters)))
            }
            return results
        }

        do {
            let file = try AVAudioFile(forReading: fileURL)
            let analyzer = try await SpeechAnalyzer(
                inputAudioFile: file,
                modules: [transcriber],
                analysisContext: context,
                finishAfterFile: false
            )
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            collector.cancel()
            throw error
        }

        return AppleSpeechEngineChoice.joinedTranscript(try await collector.value)
    }

    private static func assetState(_ status: AssetInventory.Status) -> AppleSpeechAssetState {
        switch status {
        case .installed: .installed
        case .supported: .downloadable
        case .downloading: .downloading
        case .unsupported: .unsupported
        @unknown default: .unsupported
        }
    }

    /// Requests the model and waits up to `installWait` for it. The install
    /// keeps running after a timeout, so a later dictation can use it.
    private static func installModel(for transcriber: DictationTranscriber) async -> Bool {
        let install = Task { () -> Bool in
            do {
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    try await request.downloadAndInstall()
                }
                return true
            } catch {
                logger.error("Speech model install failed: \(error.localizedDescription, privacy: .public)")
                return false
            }
        }

        // Race the install against a timer without waiting for the loser:
        // a task group would block on the install child until the download
        // finishes, however long that takes.
        let installed = await withCheckedContinuation { (continuation: CheckedContinuation<Bool?, Never>) in
            let once = ResumeOnce(continuation)
            Task { once.resume(await install.value) }
            Task {
                try? await Task.sleep(for: AppleSpeechEngineChoice.installWait)
                once.resume(nil)
            }
        }
        guard let installed else {
            logger.info("Speech model still downloading; using SFSpeechRecognizer for now")
            return false
        }
        return installed
    }
}

/// Resumes a continuation with the first value offered and ignores the rest.
private final class ResumeOnce<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: Value) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}
