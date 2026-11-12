import Foundation

/// What Whispur measured about one dictation, so a bad paste or an error can
/// be debugged afterwards without keeping the recording.
///
/// Numbers, provider names and error messages only: never audio, and never
/// transcript text beyond its length (history keeps the text).
struct DictationDiagnostics: Codable, Identifiable, Equatable {
    enum Outcome: String, Codable, CaseIterable {
        /// Text was pasted (or delivered into Whispur's own window).
        case success
        /// The user cancelled.
        case cancelled
        /// Nothing worth pasting: the recording or the transcript had no
        /// speech.
        case noSpeech
        /// An error ended the dictation.
        case failed
    }

    /// Where a dictation was when it ended.
    enum Stage: String, Codable, CaseIterable {
        case recording
        case normalization
        case transcription
        case cleanup
        case paste
        /// Before a recording started (setup, permissions) or anywhere else.
        case other
    }

    struct Audio: Codable, Equatable {
        /// Length of the captured recording.
        var recordingSeconds: Double
        var inputDeviceName: String?
        var inputSampleRate: Double
        var inputChannels: Int
        /// Length and sample count of the 16 kHz WAV sent to transcription.
        /// Nil when normalization didn't run or failed.
        var normalizedSeconds: Double?
        var normalizedSampleCount: Int64?
        /// Loudest sample, 0...1.
        var peakLevel: Double
        /// RMS over the whole recording, 0...1.
        var rmsLevel: Double
        /// Share of the recording below the speech threshold, 0...1.
        var silenceRatio: Double
        /// The recording started at shortcut key-down (early capture).
        var usedEarlyCapture: Bool
    }

    struct Transcription: Codable, Equatable {
        var provider: STTProviderID
        /// The model or model version, when Whispur knows it.
        var model: String?
        /// The selected provider when `provider` filled in for it.
        var fallbackFrom: STTProviderID?
        /// A stream was open for this dictation.
        var streamed: Bool
        /// A stream was open but a batch request produced the transcript.
        var streamFellBack: Bool
        /// From the end of recording to the raw transcript.
        var latencyMS: Int?
        /// Nil when transcription failed.
        var rawCharacterCount: Int?
        var rawWordCount: Int?
        /// Raw transcript characters per second of recording.
        var charactersPerSecond: Double?
    }

    struct Cleanup: Codable, Equatable {
        /// Nil when cleanup is switched off.
        var provider: LLMProviderID?
        var model: String?
        var latencyMS: Int?
        /// Length of the text that was pasted.
        var cleanedCharacterCount: Int
        /// Share of words cleanup changed, 0...1 (see `editDivergence`). Nil
        /// when cleanup's text wasn't pasted.
        var editDivergence: Double?
        /// Why the raw transcript was pasted instead of the cleanup.
        var rawFallbackReason: String?
        var cleanupOff: Bool
        /// The cleanup request's error, when it failed.
        var error: String?
    }

    /// The dictation id (the history entry and the provider requests share it).
    let id: UUID
    var timestamp: Date
    var outcome: Outcome
    /// For a failure, the stage it failed in; otherwise the last stage the
    /// dictation reached.
    var stage: Stage?
    var errorMessage: String?
    var audio: Audio?
    var transcription: Transcription?
    var cleanup: Cleanup?
    var appVersion: String?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        outcome: Outcome,
        stage: Stage? = nil,
        errorMessage: String? = nil,
        audio: Audio? = nil,
        transcription: Transcription? = nil,
        cleanup: Cleanup? = nil,
        appVersion: String? = DictationDiagnostics.currentAppVersion
    ) {
        self.id = id
        self.timestamp = timestamp
        self.outcome = outcome
        self.stage = stage
        self.errorMessage = errorMessage
        self.audio = audio
        self.transcription = transcription
        self.cleanup = cleanup
        self.appVersion = appVersion
    }

    /// The safety-net record a dictation starts with: if it ends without
    /// setting an outcome, this is what gets kept.
    static func unfinished(id: UUID, audio: Audio?) -> DictationDiagnostics {
        DictationDiagnostics(
            id: id,
            outcome: .failed,
            stage: .other,
            errorMessage: "The dictation ended without a recorded outcome.",
            audio: audio
        )
    }

    static let currentAppVersion: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
}

// MARK: - Measurements

extension DictationDiagnostics.Audio {
    /// Audio signals from the recorder's per-buffer metrics. Silence uses the
    /// same adaptive threshold as the speech gate.
    init(metrics: RecordingMetrics, usedEarlyCapture: Bool) {
        let frames = metrics.buffers.reduce(Int64(0)) { $0 + Int64($1.frameCount) }
        let sumOfSquares = metrics.buffers.reduce(0.0) { acc, buffer in
            acc + Double(buffer.rms) * Double(buffer.rms) * Double(buffer.frameCount)
        }
        let threshold = DictationPipeline.speechThreshold(metrics: metrics)
        let silentFrames = metrics.buffers.reduce(Int64(0)) { acc, buffer in
            Double(buffer.rms) > threshold ? acc : acc + Int64(buffer.frameCount)
        }
        self.init(
            recordingSeconds: metrics.totalDurationSeconds,
            inputDeviceName: metrics.inputDeviceName,
            inputSampleRate: metrics.sampleRate,
            inputChannels: metrics.channelCount,
            normalizedSeconds: nil,
            normalizedSampleCount: nil,
            peakLevel: Double(metrics.buffers.map(\.peak).max() ?? 0),
            rmsLevel: frames > 0 ? (sumOfSquares / Double(frames)).squareRoot() : 0,
            silenceRatio: frames > 0 ? Double(silentFrames) / Double(frames) : 1,
            usedEarlyCapture: usedEarlyCapture
        )
    }
}

extension DictationDiagnostics {
    /// Words in `text`, split on whitespace.
    static func wordCount(_ text: String) -> Int {
        text.split { $0.isWhitespace }.count
    }

    /// Characters per second of audio, or nil when the audio length is
    /// unknown.
    static func charactersPerSecond(characters: Int, seconds: Double?) -> Double? {
        guard let seconds, seconds > 0 else { return nil }
        return Double(characters) / seconds
    }

    /// Longest input `editDivergence` compares, per side. Beyond it the rest
    /// is ignored, so a very long dictation can't make the check slow.
    static let divergenceWordLimit = 3_000

    /// Word-level edit distance between two texts, divided by the longer
    /// word count: 0 when cleanup kept every word, 1 when it replaced all of
    /// them. Words are compared lowercased with punctuation stripped, so
    /// cleanup's usual capitalization and punctuation fixes don't count.
    static func editDivergence(raw: String, cleaned: String) -> Double {
        let a = Array(comparableWords(raw).prefix(divergenceWordLimit))
        let b = Array(comparableWords(cleaned).prefix(divergenceWordLimit))
        let longest = max(a.count, b.count)
        guard longest > 0 else { return 0 }
        guard !a.isEmpty, !b.isEmpty else { return 1 }

        var previous = Array(0...b.count)
        var current = Array(repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                current[j] = min(substitution, previous[j] + 1, current[j - 1] + 1)
            }
            swap(&previous, &current)
        }
        return Double(previous[b.count]) / Double(longest)
    }

    private static func comparableWords(_ text: String) -> [String] {
        text.lowercased()
            .split { $0.isWhitespace }
            .map { word in String(word.unicodeScalars.filter { !CharacterSet.punctuationCharacters.contains($0) }) }
            .filter { !$0.isEmpty }
    }

    /// The model a speech provider uses, when Whispur knows it: Parakeet's
    /// model repository, or the model picked (or defaulted) in Settings.
    static func sttModel(for provider: STTProviderID, defaults: UserDefaults = .standard) -> String? {
        if provider == .parakeet { return ParakeetModelSpec.current.repository }
        if let key = provider.modelStorageKey, let chosen = defaults.string(forKey: key), !chosen.isEmpty {
            return chosen
        }
        return provider.defaultModel
    }
}

// MARK: - Presentation

extension DictationDiagnostics {
    /// One line for Activity and Requests, e.g. "Failed in transcription ·
    /// 4:52 audio · Parakeet 1.8 s · 812 chars (2.8/s) · Cerebras 0.9 s ·
    /// 12% changed".
    var summary: String {
        var parts: [String] = [outcomeLabel]
        if let audio {
            parts.append("\(Self.formatDuration(audio.recordingSeconds)) audio")
            if audio.silenceRatio >= 0.5 {
                parts.append("\(Int((audio.silenceRatio * 100).rounded()))% silent")
            }
        }
        if let transcription {
            var stt = transcription.provider.shortName
            if let latency = transcription.latencyMS { stt += " \(Self.formatLatency(latency))" }
            parts.append(stt)
            if let characters = transcription.rawCharacterCount {
                var text = "\(characters) chars"
                if let cps = transcription.charactersPerSecond {
                    text += " (\(String(format: "%.1f", cps))/s)"
                }
                parts.append(text)
            }
        }
        if let cleanup {
            if cleanup.cleanupOff {
                parts.append("Cleanup off")
            } else if let provider = cleanup.provider {
                var llm = provider.displayName
                if let latency = cleanup.latencyMS { llm += " \(Self.formatLatency(latency))" }
                parts.append(llm)
                if let divergence = cleanup.editDivergence {
                    parts.append("\(Int((divergence * 100).rounded()))% changed")
                } else if cleanup.rawFallbackReason != nil {
                    parts.append("raw pasted")
                }
            }
        }
        return parts.joined(separator: " · ")
    }

    private var outcomeLabel: String {
        switch outcome {
        case .success: return "Pasted"
        case .cancelled: return "Cancelled"
        case .noSpeech: return "No speech"
        case .failed: return "Failed in \(stage?.rawValue ?? Stage.other.rawValue)"
        }
    }

    /// The record as pretty JSON, for "Copy diagnostics".
    var jsonString: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    static func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return String(format: "%.1f s", seconds) }
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func formatLatency(_ ms: Int) -> String {
        ms < 1000 ? "\(ms) ms" : String(format: "%.1f s", Double(ms) / 1000)
    }
}

private extension STTProviderID {
    /// The display name without the "(on this Mac)" style suffix.
    var shortName: String {
        displayName.components(separatedBy: " (").first ?? displayName
    }
}
