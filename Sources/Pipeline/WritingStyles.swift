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
                - Casual chat tone: keep contractions, slang, and relaxed lowercase; short messages \
                  need no final period. Add no greetings or sign-offs.
                """
        case .formal:
            return """
                - Polished, professional tone: full sentences, casual contractions written out \
                  ("gonna" becomes "going to"), and filler such as "you know" dropped. Add no \
                  greetings or sign-offs.
                """
        case .verbatim:
            return """
                - Minimal cleanup: keep every spoken word, including um, uh, repetitions, false \
                  starts, and replaced words; only add punctuation and apply spoken formatting.
                """
        case .codeAware:
            return """
                - The text goes into a code editor or terminal: in prose, wrap identifiers, file \
                  paths, and commands in backticks (`fetchUser`, `src/app.ts`, `npm test`). \
                  A dictation that is only a command, code, or an address stays bare: no \
                  backticks, no added capital, no final period.
                """
        }
    }
}

extension Prompts {
    /// Where a style's tone section goes: just before the output contract
    /// paragraph of the default prompt.
    static let styleInsertionMarker = "Output only the cleaned text, with no preamble"

    /// Chat apps get messages, not documents: spoken enumerations stay
    /// prose there. Added for every style but Custom.
    static let chatFormatting = """
        - Chat message: keep enumerations ("first ... second ...", "number one ...") as prose, \
          ordinal words included, never a numbered list. Lists dictated with "bullet" or "next \
          item" still apply.
        """

    /// The system prompt for a style, in an app of `group` (nil for apps
    /// outside every group). Default outside Chat returns `defaultCleanup`
    /// unchanged; Custom returns the user's prompt (or the default when it is
    /// empty) whatever the app; every other style is the default prompt with
    /// one tone and formatting section added, plus the Chat formatting
    /// section in Chat apps, so the shared rules, examples and output
    /// contract stay identical.
    static func cleanupPrompt(for style: WritingStyle, group: AppGroup? = nil, customPrompt: String) -> String {
        if style == .custom {
            let trimmed = customPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? cleanupPrompt(for: .standard, group: group, customPrompt: "") : customPrompt
        }
        guard let marker = defaultCleanup.range(of: styleInsertionMarker) else { return defaultCleanup }
        var blocks = ""
        if let section = style.promptSection {
            blocks += """
                Style: \(style.title). These style rules take priority over the cleaning rules above \
                and the examples below where they conflict:
                \(section)


                """
        }
        if let group, let section = group.promptSection {
            blocks += """
                App: \(group.title). This formatting rule takes priority over the cleaning rules \
                above and the examples below where they conflict:
                \(section)


                """
        }
        var prompt = defaultCleanup
        prompt.insert(contentsOf: blocks, at: marker.lowerBound)
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

    /// The style a group starts with. Every group starts on Default so
    /// nothing changes on upgrade; users opt groups into other styles.
    var defaultStyle: WritingStyle { .standard }

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

    /// A formatting section every style but Custom gets in this group's
    /// apps, whatever style the app is on. Nil when the shared prompt's
    /// formatting fits.
    var promptSection: String? {
        switch self {
        case .chat: return Prompts.chatFormatting
        case .email, .docs, .code: return nil
        }
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

    /// Every group and every other app on Default: cleanup reads as today.
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
    /// custom prompt falls back to Default. The app's group adds its
    /// formatting section even when an override picked the style: Slack is
    /// a chat app whatever style it is on.
    func choice(for bundleID: String?, customPrompt: String) -> CleanupStyleChoice {
        var style = settings.resolve(bundleID: bundleID).style
        if style == .custom, customPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            style = .standard
        }
        let group = bundleID.flatMap(AppGroup.group(for:))
        return CleanupStyleChoice(
            style: style,
            systemPrompt: Prompts.cleanupPrompt(for: style, group: group, customPrompt: customPrompt)
        )
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: Self.key)
        }
    }
}
