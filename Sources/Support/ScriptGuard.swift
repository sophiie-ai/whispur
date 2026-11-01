import Foundation

/// A writing system, as far as the script guard needs to tell them apart.
enum WritingScript: String, CaseIterable, Hashable {
    case latin
    case cyrillic
    case greek
    case arabic
    case hebrew
    case devanagari
    case bengali
    case tamil
    case thai
    case hangul
    case han
    case kana
    case georgian
    case armenian
    case ethiopic

    /// The script of one letter, or nil for anything that isn't a letter in a
    /// known script (digits, punctuation, symbols, emoji, whitespace).
    static func of(_ scalar: Unicode.Scalar) -> WritingScript? {
        guard scalar.properties.isAlphabetic else { return nil }
        switch scalar.value {
        case 0x0041 ... 0x005A, 0x0061 ... 0x007A, 0x00C0 ... 0x024F, 0x1E00 ... 0x1EFF, 0x2C60 ... 0x2C7F, 0xA720 ... 0xA7FF, 0xFF21 ... 0xFF3A, 0xFF41 ... 0xFF5A:
            return .latin
        case 0x0370 ... 0x03FF, 0x1F00 ... 0x1FFF:
            return .greek
        case 0x0400 ... 0x052F, 0x1C80 ... 0x1C8F, 0x2DE0 ... 0x2DFF, 0xA640 ... 0xA69F:
            return .cyrillic
        case 0x0530 ... 0x058F:
            return .armenian
        case 0x0590 ... 0x05FF, 0xFB1D ... 0xFB4F:
            return .hebrew
        case 0x0600 ... 0x06FF, 0x0750 ... 0x077F, 0x08A0 ... 0x08FF, 0xFB50 ... 0xFDFF, 0xFE70 ... 0xFEFF:
            return .arabic
        case 0x0900 ... 0x097F:
            return .devanagari
        case 0x0980 ... 0x09FF:
            return .bengali
        case 0x0B80 ... 0x0BFF:
            return .tamil
        case 0x0E00 ... 0x0E7F:
            return .thai
        case 0x10A0 ... 0x10FF:
            return .georgian
        case 0x1200 ... 0x139F:
            return .ethiopic
        case 0x1100 ... 0x11FF, 0x3130 ... 0x318F, 0xAC00 ... 0xD7AF:
            return .hangul
        case 0x3040 ... 0x30FF, 0x31F0 ... 0x31FF, 0xFF66 ... 0xFF9F:
            return .kana
        case 0x3400 ... 0x4DBF, 0x4E00 ... 0x9FFF, 0xF900 ... 0xFAFF, 0x20000 ... 0x2FFFF:
            return .han
        default:
            return nil
        }
    }

    /// Scripts each language is written in, by ISO-639-1 code. Languages not
    /// listed here disable the guard: Whispur can't judge their output.
    static let byLanguage: [String: Set<WritingScript>] = {
        var table: [String: Set<WritingScript>] = [:]
        let latin = [
            "en", "es", "fr", "de", "it", "pt", "nl", "pl", "tr", "sv", "da", "fi", "no", "nb", "nn",
            "cs", "sk", "sl", "hr", "bs", "ro", "hu", "ca", "gl", "eu", "id", "ms", "vi", "tl", "fil",
            "sw", "af", "et", "lv", "lt", "is", "ga", "cy", "mt", "sq", "az", "uz", "eo", "la",
        ]
        for code in latin { table[code] = [.latin] }
        for code in ["ru", "uk", "be", "bg", "mk", "kk", "ky", "mn", "tg"] { table[code] = [.cyrillic] }
        // Serbian is written in both.
        table["sr"] = [.cyrillic, .latin]
        table["el"] = [.greek]
        for code in ["ar", "fa", "ur", "ps"] { table[code] = [.arabic] }
        for code in ["he", "yi"] { table[code] = [.hebrew] }
        for code in ["hi", "mr", "ne", "sa"] { table[code] = [.devanagari] }
        table["bn"] = [.bengali]
        table["ta"] = [.tamil]
        table["th"] = [.thai]
        table["ka"] = [.georgian]
        table["hy"] = [.armenian]
        table["am"] = [.ethiopic]
        table["ko"] = [.hangul, .han]
        table["ja"] = [.han, .kana]
        table["zh"] = [.han]
        return table
    }()
}

/// Catches a transcript written in a script none of the user's languages
/// use: Whisper's auto-detect turning a short Spanish clip into Arabic, or
/// an English one into Japanese.
///
/// Latin is always allowed. Brand names, code and loanwords show up in Latin
/// letters in every language, so flagging them would re-run good
/// transcripts of non-Latin languages.
enum ScriptGuard {
    struct Check: Equatable {
        /// Letters in a script none of the languages use.
        let unexpectedLetters: Int
        let totalLetters: Int
        /// The out-of-place scripts, for the log.
        let unexpectedScripts: Set<WritingScript>

        /// Whether the transcript should be re-run with each language forced.
        /// A stray letter in a long transcript is tolerated; a tenth of the
        /// letters, or four or more, is not.
        var fails: Bool {
            unexpectedLetters > 0 && (unexpectedLetters * 10 >= totalLetters || unexpectedLetters >= 4)
        }
    }

    /// Scripts the languages are written in, plus Latin. Nil when any
    /// language is missing from the table: the guard then stays off.
    static func allowedScripts(for isoCodes: [String]) -> Set<WritingScript>? {
        var allowed: Set<WritingScript> = [.latin]
        for code in isoCodes {
            guard let scripts = WritingScript.byLanguage[code.lowercased()] else { return nil }
            allowed.formUnion(scripts)
        }
        return allowed
    }

    static func check(_ text: String, allowed: Set<WritingScript>) -> Check {
        var unexpected = 0
        var total = 0
        var scripts = Set<WritingScript>()
        for scalar in text.unicodeScalars {
            guard let script = WritingScript.of(scalar) else { continue }
            total += 1
            if !allowed.contains(script) {
                unexpected += 1
                scripts.insert(script)
            }
        }
        return Check(unexpectedLetters: unexpected, totalLetters: total, unexpectedScripts: scripts)
    }

    /// The check for a selection, or nil when the guard doesn't apply: fewer
    /// than two languages, or a language the table doesn't know.
    static func check(_ text: String, for selection: STTLanguageSelection) -> Check? {
        guard selection.isMultilingual, let allowed = allowedScripts(for: selection.isoCodes) else { return nil }
        return check(text, allowed: allowed)
    }
}
