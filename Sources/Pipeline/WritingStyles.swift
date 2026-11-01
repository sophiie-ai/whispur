import Foundation

/// A cleanup style: how the cleaned text should read.
enum WritingStyle: String, Codable, CaseIterable, Identifiable {
    /// Today's cleanup prompt, unchanged.
    case standard = "default"
    case casual
    case formal
    /// Minimal cleanup: punctuation only, every spoken word kept.
    case verbatim
    case codeAware
    /// The user's own cleanup prompt.
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: return "Default"
        case .casual: return "Casual"
        case .formal: return "Formal"
        case .verbatim: return "Verbatim"
        case .codeAware: return "Code-aware"
        case .custom: return "Custom"
        }
    }

    var icon: String {
        switch self {
        case .standard: return "sparkles"
        case .casual: return "bubble.left"
        case .formal: return "envelope"
        case .verbatim: return "quote.opening"
        case .codeAware: return "chevron.left.forwardslash.chevron.right"
        case .custom: return "slider.horizontal.3"
        }
    }

    /// What "um yeah sounds good ship it" (or a rename) comes out as.
    var sample: String {
        switch self {
        case .standard: return "Yeah, sounds good. Ship it."
        case .casual: return "yeah sounds good, ship it"
        case .formal: return "Thanks, sounds good. Please proceed."
        case .verbatim: return "um yeah sounds good, ship it"
        case .codeAware: return "Rename `fetchUser` to `loadUser`."
        case .custom: return "Your own cleanup prompt."
        }
    }

    /// The tone and formatting section added to the shared cleanup prompt.
    /// Nil for Default (the prompt is used as is) and Custom.
    var promptSection: String? {
        switch self {
        case .standard, .custom:
            return nil
        case .casual:
            return """
                - Casual chat tone. Keep contractions, slang, and lowercase if the speaker sounds \
                  relaxed. Short messages need no final period. Use light punctuation: commas and \
                  question marks, rarely semicolons.
                - Do not add greetings, sign-offs, or politeness the speaker didn't say.
                """
        case .formal:
            return """
                - Polished, professional tone. Use full sentences with standard capitalization and \
                  punctuation.
                - Write casual contractions of speech in full ("gonna" becomes "going to", \
                  "wanna" becomes "want to") and drop filler such as "like", "you know", or \
                  "kind of" when it adds no meaning. Keep every other word.
                - Do not add greetings, sign-offs, or content the speaker didn't say.
                """
        case .verbatim:
            return """
                - Minimal cleanup. Keep every spoken word, including hesitation sounds (um, uh), \
                  repetitions, false starts, and self-corrections with the replaced words.
                - Only add punctuation and capitalization, apply explicit spoken formatting \
                  commands, and remove speech-to-text labels.
                """
        case .codeAware:
            return """
                - The text is going into a code editor, terminal, or developer tool.
                - In prose, wrap identifiers, function names, file paths, and commands in \
                  backticks (`fetchUser`, `src/app.ts`, `npm test`).
                - When the whole dictation is a command or code, output it bare: no backticks, \
                  no capitalized first letter unless the code needs one, no final period.
                """
        }
    }
}

extension Prompts {
    /// Where a style's tone section goes: just before the output contract
    /// paragraph of the default prompt.
    static let styleInsertionMarker = "Output only the cleaned text, with no preamble"

    /// The system prompt for a style. Default returns `defaultCleanup`
    /// unchanged; Custom returns the user's prompt (or the default when it is
    /// empty); every other style is the default prompt with one tone and
    /// formatting section added, so the shared rules, examples and output
    /// contract stay identical.
    static func cleanupPrompt(for style: WritingStyle, customPrompt: String) -> String {
        if style == .custom {
            let trimmed = customPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? defaultCleanup : customPrompt
        }
        guard let section = style.promptSection,
              let marker = defaultCleanup.range(of: styleInsertionMarker) else {
            return defaultCleanup
        }
        let block = """
            Style: \(style.title). These style rules take priority over the cleaning rules above \
            and the examples below where they conflict:
            \(section)


            """
        var prompt = defaultCleanup
        prompt.insert(contentsOf: block, at: marker.lowerBound)
        return prompt
    }
}

/// A fixed set of apps that share a style.
enum AppGroup: String, Codable, CaseIterable, Identifiable {
    case chat
    case email
    case docs
    case code

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chat: return "Chat"
        case .email: return "Email"
        case .docs: return "Docs"
        case .code: return "Code"
        }
    }

    var icon: String {
        switch self {
        case .chat: return "bubble.left.and.bubble.right"
        case .email: return "envelope"
        case .docs: return "doc.text"
        case .code: return "chevron.left.forwardslash.chevron.right"
        }
    }

    /// The style a group starts with.
    var defaultStyle: WritingStyle {
        switch self {
        case .chat: return .casual
        case .email: return .formal
        case .docs: return .standard
        case .code: return .codeAware
        }
    }

    /// Display names, in the order shown under the group.
    var appNames: [String] {
        switch self {
        case .chat: return ["Slack", "Messages", "WhatsApp", "Discord", "Teams"]
        case .email: return ["Mail", "Outlook"]
        case .docs: return ["Notes", "Pages", "Word", "Notion", "Obsidian"]
        case .code: return ["Xcode", "VS Code", "Cursor", "Terminal", "iTerm", "Ghostty", "Zed"]
        }
    }

    var bundleIDs: Set<String> {
        switch self {
        case .chat:
            return ["com.tinyspeck.slackmacgap", "com.apple.MobileSMS", "net.whatsapp.WhatsApp",
                    "desktop.WhatsApp", "com.hnc.Discord", "com.microsoft.teams2", "com.microsoft.teams"]
        case .email:
            return ["com.apple.mail", "com.microsoft.Outlook"]
        case .docs:
            return ["com.apple.Notes", "com.apple.iWork.Pages", "com.microsoft.Word", "notion.id", "md.obsidian"]
        case .code:
            return ["com.apple.dt.Xcode", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92",
                    "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.zed.Zed"]
        }
    }

    static func group(for bundleID: String) -> AppGroup? {
        allCases.first { $0.bundleIDs.contains(bundleID) }
    }
}

/// A style chosen for one app, overriding its group and the default.
struct AppStyleOverride: Codable, Equatable, Identifiable {
    let bundleID: String
    var name: String
    var style: WritingStyle

    var id: String { bundleID }
}

/// Every style choice the user has made.
struct StyleSettings: Codable, Equatable {
    /// Used for apps outside every group and without an override.
    var fallback: WritingStyle
    var groups: [AppGroup: WritingStyle]
    var overrides: [AppStyleOverride]

    /// Group defaults; the default style stays as today.
    static let initial = StyleSettings(
        fallback: .standard,
        groups: Dictionary(uniqueKeysWithValues: AppGroup.allCases.map { ($0, $0.defaultStyle) }),
        overrides: []
    )

    /// Someone with a custom prompt today has it applied in every app; they
    /// keep that until they choose otherwise.
    static let customEverywhere = StyleSettings(
        fallback: .custom,
        groups: Dictionary(uniqueKeysWithValues: AppGroup.allCases.map { ($0, .custom) }),
        overrides: []
    )

    func style(for group: AppGroup) -> WritingStyle {
        groups[group] ?? group.defaultStyle
    }

    /// Why an app got its style.
    enum Reason: Equatable {
        case override
        case group(AppGroup)
        case fallback
    }

    /// Per-app override, then the app's group, then the default.
    func resolve(bundleID: String?) -> (style: WritingStyle, reason: Reason) {
        if let bundleID {
            if let override = overrides.first(where: { $0.bundleID == bundleID }) {
                return (override.style, .override)
            }
            if let group = AppGroup.group(for: bundleID) {
                return (style(for: group), .group(group))
            }
        }
        return (fallback, .fallback)
    }
}

/// The style picked for one cleanup request.
struct CleanupStyleChoice: Equatable {
    let style: WritingStyle
    let systemPrompt: String
}

/// Persists `StyleSettings` in UserDefaults as JSON.
@MainActor
final class StyleStore: ObservableObject {
    static let key = "writingStyles"

    @Published var settings: StyleSettings {
        didSet {
            guard settings != oldValue else { return }
            save()
        }
    }

    private let defaults: UserDefaults

    /// - Parameter hasCustomPrompt: Whether the user already has a custom
    ///   cleanup prompt. Read only the first time, to keep it applying in
    ///   every app.
    init(defaults: UserDefaults = .standard, hasCustomPrompt: Bool) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let stored = try? JSONDecoder().decode(StyleSettings.self, from: data) {
            settings = stored
        } else {
            settings = hasCustomPrompt ? .customEverywhere : .initial
            save()
        }
    }

    func setFallback(_ style: WritingStyle) {
        settings.fallback = style
    }

    func setStyle(_ style: WritingStyle, for group: AppGroup) {
        settings.groups[group] = style
    }

    /// Adds or updates an app's own style.
    func setOverride(bundleID: String, name: String, style: WritingStyle) {
        if let index = settings.overrides.firstIndex(where: { $0.bundleID == bundleID }) {
            settings.overrides[index].style = style
        } else {
            settings.overrides.append(AppStyleOverride(bundleID: bundleID, name: name, style: style))
        }
    }

    func removeOverride(bundleID: String) {
        settings.overrides.removeAll { $0.bundleID == bundleID }
    }

    func reset() {
        settings = .initial
    }

    /// The style and system prompt for an app. A Custom choice with no
    /// custom prompt falls back to Default.
    func choice(for bundleID: String?, customPrompt: String) -> CleanupStyleChoice {
        var style = settings.resolve(bundleID: bundleID).style
        if style == .custom, customPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            style = .standard
        }
        return CleanupStyleChoice(style: style, systemPrompt: Prompts.cleanupPrompt(for: style, customPrompt: customPrompt))
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: Self.key)
        }
    }
}
