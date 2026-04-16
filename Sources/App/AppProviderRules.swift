import AppKit
import Foundation
import os

private let logger = Logger(subsystem: "ai.sophiie.whispur", category: "AppRules")

/// Per-app override. When the frontmost app matches `bundleIdentifier`,
/// the pipeline swaps in these providers/mode for this dictation.
struct AppProviderRule: Codable, Identifiable, Equatable {
    var id: UUID
    var bundleIdentifier: String
    var appDisplayName: String
    var sttOverride: STTProviderID?
    var llmOverride: LLMProviderID?
    var modeID: DictationModeID?

    init(
        id: UUID = UUID(),
        bundleIdentifier: String,
        appDisplayName: String,
        sttOverride: STTProviderID? = nil,
        llmOverride: LLMProviderID? = nil,
        modeID: DictationModeID? = nil
    ) {
        self.id = id
        self.bundleIdentifier = bundleIdentifier
        self.appDisplayName = appDisplayName
        self.sttOverride = sttOverride
        self.llmOverride = llmOverride
        self.modeID = modeID
    }

    var summary: String {
        var parts: [String] = []
        if let sttOverride { parts.append("Speech: \(sttOverride.displayName)") }
        if let llmOverride { parts.append("Cleanup: \(llmOverride.displayName)") }
        if let modeID { parts.append("Mode: \(modeID.displayName)") }
        return parts.isEmpty ? "No overrides" : parts.joined(separator: " · ")
    }
}

/// Stores and resolves per-app provider rules.
@MainActor
final class AppProviderRulesStore: ObservableObject {
    private static let storageKey = "whispur.appProviderRules"

    @Published private(set) var rules: [AppProviderRule]

    init() {
        self.rules = Self.load()
    }

    func matching(bundleID: String?) -> AppProviderRule? {
        guard let bundleID else { return nil }
        return rules.first { $0.bundleIdentifier == bundleID }
    }

    /// Rule that applies to whichever app is frontmost right now.
    func currentRule() -> AppProviderRule? {
        matching(bundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    }

    func upsert(_ rule: AppProviderRule) {
        if let idx = rules.firstIndex(where: { $0.id == rule.id }) {
            rules[idx] = rule
        } else {
            rules.append(rule)
        }
        save()
    }

    func remove(_ rule: AppProviderRule) {
        rules.removeAll { $0.id == rule.id }
        save()
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(rules)
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        } catch {
            logger.error("Failed to save app provider rules: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func load() -> [AppProviderRule] {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return [] }
        do {
            return try JSONDecoder().decode([AppProviderRule].self, from: data)
        } catch {
            logger.error("Failed to decode app provider rules: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }
}
