import Foundation

/// Who sees the language question and the download pill in onboarding.
/// Pure, so the gating is unit tested.
enum OnboardingSpeechSetup {
    /// Onboarding frames speech setup around the Parakeet download: the
    /// default resolver gave this user Parakeet (no cloud speech key, a Mac
    /// that runs it) and its model isn't on disk yet. Anyone with a cloud
    /// key, an Intel Mac, another chosen provider or the model already
    /// downloaded gets no download framing and no pill.
    static func usesParakeetDownload(selected: STTProviderID, parakeetSupported: Bool, modelInstalled: Bool) -> Bool {
        selected == .parakeet && parakeetSupported && !modelInstalled
    }

    /// The language step shows with the download framing, and for anyone
    /// who has never set "Languages I speak".
    static func asksLanguages(usesParakeetDownload: Bool, languagesStored: Bool) -> Bool {
        usesParakeetDownload || !languagesStored
    }

    /// The pill sits in the top bar on every screen after the language one.
    static func showsDownloadPill(on step: OnboardingStep, plan: OnboardingPlan, usesParakeetDownload: Bool) -> Bool {
        usesParakeetDownload && plan.asksLanguages && plan.isAfter(step, .languages)
    }

    /// The preselected language: the system locale's own entry when the
    /// catalog has it, else the catalog's first entry in that language,
    /// else US English.
    static func defaultLanguages(systemLocaleIdentifier: String) -> STTLanguageSelection {
        let code = systemLocaleIdentifier
            .split(separator: "@").first.map(String.init)?
            .replacingOccurrences(of: "_", with: "-") ?? ""
        let parts = code.split(separator: "-").map(String.init)
        let language = parts.first?.lowercased() ?? ""
        let region = parts.count > 1 ? parts.last!.uppercased() : ""
        let catalog = STTLanguageCatalog.all
        if let exact = catalog.first(where: { $0.code == "\(language)-\(region)" }) {
            return .single(code: exact.code)
        }
        if let sameLanguage = catalog.first(where: { $0.iso639_1 == language }) {
            return .single(code: sameLanguage.code)
        }
        return .single(code: "en-US")
    }
}

/// What the top-bar download pill says for each model state.
struct OnboardingDownloadPill: Equatable {
    enum Tone: Equatable {
        case progress
        case ready
        case waiting
        case problem
    }

    enum Action: Equatable {
        case retry
        case downloadNow

        var title: String {
            switch self {
            case .retry: return "Retry"
            case .downloadNow: return "Download"
            }
        }
    }

    let text: String
    let symbol: String
    let tone: Tone
    /// 0...1 while bytes are arriving; nil otherwise.
    let fraction: Double?
    let action: Action?

    static func content(for state: ParakeetModelManager.DownloadState) -> OnboardingDownloadPill {
        switch state {
        case let .downloading(fraction, isPreparing):
            if isPreparing {
                return .init(text: "Preparing speech model", symbol: "gearshape", tone: .progress, fraction: nil, action: nil)
            }
            let clamped = min(max(fraction, 0), 1)
            return .init(text: "Speech model \(Int(clamped * 100))%", symbol: "arrow.down", tone: .progress, fraction: clamped, action: nil)
        case .installed:
            return .init(text: "Speech model ready", symbol: "checkmark.circle.fill", tone: .ready, fraction: nil, action: nil)
        case .failed:
            return .init(text: "Download failed", symbol: "exclamationmark.triangle.fill", tone: .problem, fraction: nil, action: .retry)
        case .waitingForNetwork:
            return .init(text: "Waiting for Wi-Fi", symbol: "wifi", tone: .waiting, fraction: nil, action: .downloadNow)
        case .notDownloaded:
            return .init(text: "Speech model", symbol: "arrow.down.circle", tone: .waiting, fraction: nil, action: .downloadNow)
        }
    }

    /// The pill's tooltip: what's downloading, and that dictation (and the
    /// Try it step) already works meanwhile.
    static var help: String {
        let size = ByteCountFormatter.string(fromByteCount: ParakeetModelSpec.current.downloadBytes, countStyle: .file)
        return "Whispur's on-device speech model (Parakeet, about \(size)). You can dictate and use Try it right away: Apple's on-device recognition fills in until the model is ready."
    }
}
