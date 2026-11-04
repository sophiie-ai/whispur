import Foundation

/// The "Next steps" card on the Dictation page, shown once onboarding ends.
/// Each item ticks itself off from real state; this type only decides which
/// items show, which are done, and whether the card shows at all.
enum NextSteps {
    static let baselineKey = "whispur.nextSteps.baseline"
    static let dismissedKey = "whispur.nextSteps.dismissed"

    /// Recorded when onboarding ends. Users who finished onboarding before
    /// the card existed have none, so they never see it.
    struct Baseline: Codable, Equatable {
        /// Dictations counted so far, including the onboarding Try it.
        var dictationCount: Int
        /// No cleanup key at the time, so the card offers to add one.
        var offersCleanupKey: Bool
    }

    enum Item: String, CaseIterable, Identifiable {
        case dictate
        case dictionary
        case style
        case cleanupKey

        var id: String { rawValue }

        /// Optional items never hold back "All set".
        var isOptional: Bool { self == .cleanupKey }

        /// The page that completes it. Dictating happens in another app.
        var tab: SettingsTab? {
            switch self {
            case .dictate: return nil
            case .dictionary: return .dictionary
            case .style: return .styles
            case .cleanupKey: return .providers
            }
        }
    }

    /// What the app knows right now.
    struct Signals: Equatable {
        var dictationCount: Int
        var termCount: Int
        var styles: StyleSettings
        var cleanupEnabled: Bool
        var cleanupKeyReady: Bool
    }

    enum Display: Equatable {
        case hidden
        case steps([Item], done: Set<Item>)
        case allSet
    }

    static func display(baseline: Baseline?, dismissed: Bool, signals: Signals) -> Display {
        guard let baseline, !dismissed else { return .hidden }
        var items: [Item] = [.dictate, .dictionary]
        // Styles only change how cleanup reads, so they wait for cleanup.
        if signals.cleanupEnabled { items.append(.style) }
        if baseline.offersCleanupKey { items.append(.cleanupKey) }

        let done = Set(items.filter { isDone($0, baseline: baseline, signals: signals) })
        if items.allSatisfy({ $0.isOptional || done.contains($0) }) { return .allSet }
        return .steps(items, done: done)
    }

    static func isDone(_ item: Item, baseline: Baseline, signals: Signals) -> Bool {
        switch item {
        case .dictate: return signals.dictationCount > baseline.dictationCount
        case .dictionary: return signals.termCount > 0
        case .style: return hasPickedStyle(signals.styles)
        case .cleanupKey: return signals.cleanupKeyReady
        }
    }

    /// Whispur seeds one of two starting style setups; anything else is the
    /// user's own choice.
    static func hasPickedStyle(_ settings: StyleSettings) -> Bool {
        settings != .initial && settings != .customEverywhere
    }
}
