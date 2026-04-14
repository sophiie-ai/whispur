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

    /// Languages covered by Deepgram nova-3's `language=multi` mode.
    /// Source: https://developers.deepgram.com/docs/models-languages-overview
    static let deepgramNova3MultiISO: Set<String> = [
        "en", "es", "fr", "de", "hi", "ru", "pt", "ja", "it", "nl",
    ]
}
