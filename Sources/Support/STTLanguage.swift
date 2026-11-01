import Foundation

/// A selectable language for speech-to-text.
///
/// Codes are BCP-47 (e.g. `en-US`) so Apple's `SFSpeechRecognizer` can use them
/// directly. Cloud providers consume only the primary subtag (ISO-639-1).
struct STTLanguage: Identifiable, Hashable {
    let code: String
    let displayName: String

    var id: String { code }

    /// Primary subtag (ISO-639-1) for providers that accept only language codes.
    var iso639_1: String {
        code.split(separator: "-").first.map(String.init) ?? code
    }
}

/// The languages the user speaks, applied uniformly across STT providers.
///
/// Empty means auto-detect. Each provider translates the set into its own
/// parameter shape via `STTLanguageResolver`: providers that accept several
/// languages get all of them, single-language providers get the language
/// when there is exactly one and their auto mode otherwise (with
/// `MultiLanguageTranscription`'s script guard behind it).
struct STTLanguageSelection: Equatable, Hashable {
    /// BCP-47 codes in the order the user added them, without duplicates.
    let codes: [String]

    init(codes: [String]) {
        var seen = Set<String>()
        self.codes = codes
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    static let auto = STTLanguageSelection(codes: [])

    static func single(code: String) -> STTLanguageSelection {
        STTLanguageSelection(codes: [code])
    }

    var isAuto: Bool { codes.isEmpty }

    /// Distinct ISO-639-1 codes, in order. `en-US` and `en-GB` are one
    /// language to a provider that only takes language codes.
    var isoCodes: [String] {
        var seen = Set<String>()
        return codes
            .map { STTLanguage(code: $0, displayName: "").iso639_1 }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// The one language to send to a single-language provider, or nil when
    /// the set is empty (auto) or holds several languages.
    var singleISOCode: String? {
        let codes = isoCodes
        return codes.count == 1 ? codes[0] : nil
    }

    /// True when the user speaks two or more distinct languages.
    var isMultilingual: Bool { isoCodes.count >= 2 }

    /// The selection narrowed to one of its languages, keeping the first
    /// BCP-47 code the user picked for it.
    func forcing(iso: String) -> STTLanguageSelection {
        let code = codes.first { STTLanguage(code: $0, displayName: "").iso639_1 == iso } ?? iso
        return .single(code: code)
    }

    /// Compact storage form for `@AppStorage`: comma-separated codes. Empty
    /// string = auto. A value written by the old single picker (one code)
    /// reads back as a one-language set.
    var storageValue: String {
        codes.joined(separator: ",")
    }

    init(storageValue: String) {
        self.init(codes: storageValue.split(separator: ",").map(String.init))
    }

    /// Display summary for Settings: "Auto-detect" or the language names.
    var summary: String {
        isAuto ? "Auto-detect" : codes.map(STTLanguageCatalog.displayName(for:)).joined(separator: ", ")
    }
}

enum STTLanguageCatalog {
    /// Curated subset of languages broadly supported by Whispur's STT providers.
    static let all: [STTLanguage] = [
        .init(code: "en-US", displayName: "English (US)"),
        .init(code: "en-GB", displayName: "English (UK)"),
        .init(code: "es-ES", displayName: "Spanish (Spain)"),
        .init(code: "es-MX", displayName: "Spanish (Mexico)"),
        .init(code: "fr-FR", displayName: "French"),
        .init(code: "de-DE", displayName: "German"),
        .init(code: "it-IT", displayName: "Italian"),
        .init(code: "pt-BR", displayName: "Portuguese (Brazil)"),
        .init(code: "pt-PT", displayName: "Portuguese (Portugal)"),
        .init(code: "nl-NL", displayName: "Dutch"),
        .init(code: "pl-PL", displayName: "Polish"),
        .init(code: "ru-RU", displayName: "Russian"),
        .init(code: "uk-UA", displayName: "Ukrainian"),
        .init(code: "ja-JP", displayName: "Japanese"),
        .init(code: "ko-KR", displayName: "Korean"),
        .init(code: "zh-CN", displayName: "Chinese (Simplified)"),
        .init(code: "zh-TW", displayName: "Chinese (Traditional)"),
        .init(code: "hi-IN", displayName: "Hindi"),
        .init(code: "ar-SA", displayName: "Arabic"),
        .init(code: "tr-TR", displayName: "Turkish"),
        .init(code: "sv-SE", displayName: "Swedish"),
        .init(code: "da-DK", displayName: "Danish"),
        .init(code: "fi-FI", displayName: "Finnish"),
        .init(code: "no-NO", displayName: "Norwegian"),
        .init(code: "cs-CZ", displayName: "Czech"),
        .init(code: "el-GR", displayName: "Greek"),
        .init(code: "he-IL", displayName: "Hebrew"),
        .init(code: "id-ID", displayName: "Indonesian"),
        .init(code: "th-TH", displayName: "Thai"),
        .init(code: "vi-VN", displayName: "Vietnamese"),
        .init(code: "ro-RO", displayName: "Romanian"),
        .init(code: "hu-HU", displayName: "Hungarian"),
        .init(code: "ca-ES", displayName: "Catalan"),
    ]

    static func language(for code: String) -> STTLanguage? {
        all.first { $0.code == code }
    }

    static func displayName(for code: String) -> String {
        language(for: code)?.displayName ?? code
    }
}

/// Per-provider translation of `STTLanguageSelection` into native API shapes.
///
/// Each provider calls the helper it needs. This keeps the catalog in one place
/// and guarantees consistent behavior across providers (e.g. `.auto` never
/// silently falls back to "send nothing and hope the model detects correctly"
/// for providers that have a better explicit mode).
enum STTLanguageResolver {
    /// OpenAI Whisper / Groq Whisper / ElevenLabs Scribe / Mistral: one
    /// ISO-639-1 code when the user speaks exactly one language, nil (the
    /// provider's auto-detect) for none or several.
    static func iso639_1(for selection: STTLanguageSelection) -> String? {
        selection.singleISOCode
    }

    /// Deepgram nova-3: no languages → `language=multi` (code-switching
    /// across its multilingual set); one language → that BCP-47 code; two
    /// or more → `multi`, since `language` takes a single value.
    enum DeepgramLanguage: Equatable {
        case multi
        case single(String)
    }

    static func deepgram(for selection: STTLanguageSelection) -> DeepgramLanguage {
        guard selection.singleISOCode != nil, let code = selection.codes.first else {
            return .multi
        }
        return .single(code)
    }

    /// Apple `SFSpeechRecognizer` takes one locale and has no auto mode.
    /// One language → that locale. Several → the system locale when its
    /// language is in the set, else the first one the user picked. None →
    /// the system locale if it's in the catalog, otherwise `en-US`.
    static func appleLocale(for selection: STTLanguageSelection, systemIdentifier: String = Locale.current.identifier) -> String {
        let systemPrimary = systemIdentifier.split(whereSeparator: { $0 == "_" || $0 == "-" }).first.map(String.init) ?? systemIdentifier
        if let first = selection.codes.first {
            if selection.singleISOCode != nil { return first }
            return selection.codes.first { STTLanguage(code: $0, displayName: "").iso639_1 == systemPrimary } ?? first
        }
        let systemID = systemIdentifier.replacingOccurrences(of: "_", with: "-")
        if STTLanguageCatalog.language(for: systemID) != nil {
            return systemID
        }
        if let match = STTLanguageCatalog.all.first(where: { $0.iso639_1 == systemPrimary }) {
            return match.code
        }
        return "en-US"
    }
}
