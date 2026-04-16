import Foundation
import os

private let logger = Logger(subsystem: "ai.sophiie.whispur", category: "Modes")

/// Built-in dictation modes. Each ships a cleanup prompt tuned for the
/// context it names — the user can override any of these per-mode in
/// settings.
enum DictationModeID: String, Codable, CaseIterable, Identifiable {
    case general
    case meeting
    case email
    case code
    case creative

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .general: "General"
        case .meeting: "Meeting Notes"
        case .email: "Email"
        case .code: "Code Comment"
        case .creative: "Creative"
        }
    }

    var icon: String {
        switch self {
        case .general: "text.bubble"
        case .meeting: "person.2.wave.2"
        case .email: "envelope"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .creative: "sparkles"
        }
    }

    var subtitle: String {
        switch self {
        case .general: "Balanced cleanup for any text field."
        case .meeting: "Bullet points, action items, decisions."
        case .email: "Greeting, clear prose, polite sign-off."
        case .code: "Technical tone, preserve identifiers and casing."
        case .creative: "Looser cleanup — preserve voice and rhythm."
        }
    }

    var defaultPrompt: String {
        switch self {
        case .general: return Prompts.defaultCleanup
        case .meeting: return Prompts.meetingNotes
        case .email: return Prompts.email
        case .code: return Prompts.codeComment
        case .creative: return Prompts.creative
        }
    }
}

/// A resolved mode — either a built-in default or the user's customized
/// version of one.
struct DictationMode: Equatable {
    let id: DictationModeID
    let prompt: String

    static let general = DictationMode(id: .general, prompt: Prompts.defaultCleanup)
}

/// Reads/writes per-mode custom prompts. Customizations live in
/// UserDefaults keyed by the mode ID; an empty value means "use the
/// built-in default".
@MainActor
final class DictationModeStore: ObservableObject {
    @Published private(set) var customPromptsByMode: [DictationModeID: String]

    init() {
        self.customPromptsByMode = Self.load()
    }

    func resolvedPrompt(for id: DictationModeID) -> String {
        if let custom = customPromptsByMode[id], !custom.isEmpty {
            return custom
        }
        return id.defaultPrompt
    }

    func setCustomPrompt(_ prompt: String, for id: DictationModeID) {
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            customPromptsByMode.removeValue(forKey: id)
        } else {
            customPromptsByMode[id] = prompt
        }
        save()
    }

    func isCustomized(_ id: DictationModeID) -> Bool {
        guard let custom = customPromptsByMode[id] else { return false }
        return !custom.isEmpty
    }

    private static let storageKey = "whispur.dictationModes.customPrompts"

    private func save() {
        do {
            let data = try JSONEncoder().encode(customPromptsByMode.mapKeys(\.rawValue))
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        } catch {
            logger.error("Failed to save mode prompts: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func load() -> [DictationModeID: String] {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return [:] }
        do {
            let raw = try JSONDecoder().decode([String: String].self, from: data)
            var result: [DictationModeID: String] = [:]
            for (key, value) in raw {
                if let id = DictationModeID(rawValue: key) {
                    result[id] = value
                }
            }
            return result
        } catch {
            logger.error("Failed to decode mode prompts: \(error.localizedDescription, privacy: .public)")
            return [:]
        }
    }
}

private extension Dictionary {
    func mapKeys<T: Hashable>(_ transform: (Key) -> T) -> [T: Value] {
        var result: [T: Value] = [:]
        for (key, value) in self {
            result[transform(key)] = value
        }
        return result
    }
}
