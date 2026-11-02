import Foundation

// MARK: - Hardware

/// Whether this Mac can run Parakeet.
///
/// FluidAudio refuses to run its Parakeet models anywhere but Apple Silicon
/// (`AsrModels.isModelValid` throws "Parakeet models require Apple Silicon"):
/// the encoder is built for the Neural Engine, which Intel Macs don't have.
/// Parakeet Ultra itself needs macOS 14, the app's own minimum, so the OS
/// check only matters if that minimum ever drops.
enum ParakeetSupport {
    static let minimumOS = OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0)

    static var isSupported: Bool {
        isSupported(isAppleSilicon: isAppleSilicon, os: ProcessInfo.processInfo.operatingSystemVersion)
    }

    static func isSupported(isAppleSilicon: Bool, os: OperatingSystemVersion) -> Bool {
        guard isAppleSilicon else { return false }
        return (os.majorVersion, os.minorVersion, os.patchVersion)
            >= (minimumOS.majorVersion, minimumOS.minorVersion, minimumOS.patchVersion)
    }

    /// The same compile-time check FluidAudio makes.
    static var isAppleSilicon: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }
}

// MARK: - Keys

/// The one definition of "a user without keys".
///
/// A user has no speech-to-text key when none of the cloud speech providers
/// (every provider that isn't on-device: OpenAI, Groq, Deepgram, ElevenLabs,
/// Mistral, Meta) has its key stored. Blank values don't count. Cleanup-only
/// keys (Anthropic, Bedrock) don't count either; OpenAI and Groq keys do,
/// even if the user only added them for cleanup, because they also unlock
/// that provider's speech-to-text.
enum CloudSTTKeys {
    static var providers: [STTProviderID] {
        STTProviderID.allCases.filter(\.requiresAPIKey)
    }

    static var keys: [KeychainKey] {
        var seen = Set<KeychainKey>()
        return providers.flatMap(\.keychainKeys).filter { seen.insert($0).inserted }
    }

    static func hasAny(_ value: (KeychainKey) -> String?) -> Bool {
        keys.contains { key in
            !(value(key)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }
    }
}

// MARK: - Default resolution

/// Which speech provider a user gets when they never picked one.
enum STTDefaultResolver {
    /// The `@AppStorage` key behind `AppState.selectedSTT`.
    static let selectedSTTKey = "selectedSTT"
    /// Set when Whispur, not the user, picked Parakeet. Drives the
    /// automatic model download.
    static let automaticParakeetKey = "sttParakeetAutomaticDefault"

    /// What `selectedSTT` holds. `@AppStorage` hides the difference between
    /// "never chosen" and "chose Apple" behind its default value, so this
    /// reads the raw object.
    enum StoredChoice: Equatable {
        case neverChosen
        case chosen(STTProviderID)
    }

    static func storedChoice(in defaults: UserDefaults) -> StoredChoice {
        guard let raw = defaults.object(forKey: selectedSTTKey) else { return .neverChosen }
        // A value from a provider this build doesn't know is still a choice;
        // `@AppStorage` shows it as Apple.
        return .chosen((raw as? String).flatMap(STTProviderID.init(rawValue:)) ?? .apple)
    }

    /// The provider in effect.
    ///
    /// - A stored choice always wins.
    /// - Never chosen, no cloud speech key, and a Mac that runs Parakeet:
    ///   Parakeet.
    /// - Never chosen otherwise: Apple, as before Parakeet existed.
    static func effectiveProvider(
        stored: StoredChoice,
        hasCloudSTTKey: Bool,
        parakeetSupported: Bool
    ) -> STTProviderID {
        switch stored {
        case let .chosen(provider):
            return provider
        case .neverChosen:
            return !hasCloudSTTKey && parakeetSupported ? .parakeet : .apple
        }
    }

    /// Stores Parakeet for a user it is the default for, so it stays their
    /// provider when they add a cloud key later. Leaves every other user
    /// untouched (an explicit choice, or Apple by default with nothing
    /// stored). `hasCloudSTTKey` is only read for a user who never chose.
    ///
    /// - Returns: true when Parakeet was stored.
    @discardableResult
    static func adoptParakeetIfDefault(
        defaults: UserDefaults,
        hasCloudSTTKey: () -> Bool,
        parakeetSupported: Bool
    ) -> Bool {
        guard storedChoice(in: defaults) == .neverChosen, parakeetSupported, !hasCloudSTTKey() else { return false }
        defaults.set(STTProviderID.parakeet.rawValue, forKey: selectedSTTKey)
        defaults.set(true, forKey: automaticParakeetKey)
        return true
    }
}

// MARK: - Routing

/// Which provider actually transcribes a recording.
struct STTRoute: Equatable {
    /// The provider that transcribes.
    let provider: STTProviderID
    /// The selected provider when it couldn't run and `provider` filled in.
    let fallbackFrom: STTProviderID?

    /// Parakeet with its model still missing (not downloaded, downloading,
    /// deleted) transcribes with Apple on-device instead, so dictation works
    /// from the first minute. Everything else runs as selected.
    static func resolve(selected: STTProviderID, parakeetInstalled: Bool) -> STTRoute {
        if selected == .parakeet, !parakeetInstalled {
            return STTRoute(provider: .apple, fallbackFrom: .parakeet)
        }
        return STTRoute(provider: selected, fallbackFrom: nil)
    }
}

// MARK: - Automatic download

/// The parts of `ParakeetModelManager` the automatic download drives.
@MainActor
protocol ParakeetModelDownloading: AnyObject {
    var downloadState: ParakeetModelManager.DownloadState { get }
    var isInstalled: Bool { get }
    var isDownloading: Bool { get }
    /// The running download was started by `ParakeetAutoDownload`, not the user.
    var isAutomaticDownload: Bool { get }
    func download(priority: TaskPriority?, automatic: Bool)
    /// Stops an automatic download (partial files stay and resume) or marks
    /// one that hasn't started yet as waiting for an unmetered network.
    func pauseForNetwork()
    /// Cancels without counting as the user stopping it.
    func cancelAutomaticDownload()
}

/// Downloads the Parakeet model in the background for users Parakeet became
/// the default for, without asking.
///
/// It fires at most once per launch, only while Parakeet is the selected
/// provider and was picked automatically, and only until the model is on
/// disk. The user cancelling or deleting the model, or picking another
/// provider, ends it for good. A failed download stays failed (Settings
/// offers Retry) and is tried once more, silently, at the next launch.
/// On a metered or Low Data Mode network it waits for a better one.
@MainActor
final class ParakeetAutoDownload: ObservableObject {
    private let defaults: UserDefaults
    private let model: ParakeetModelDownloading

    /// Downloads this object started, including resumes after a network
    /// wait. For tests.
    private(set) var startCount = 0
    private var firedThisLaunch = false
    /// nil until the network monitor's first report.
    private var networkIsConstrained: Bool?
    private var launchWaitingForNetworkStatus = false

    init(defaults: UserDefaults = .standard, model: ParakeetModelDownloading) {
        self.defaults = defaults
        self.model = model
    }

    /// Parakeet was picked automatically and its download hasn't finished
    /// or been stopped by the user.
    var isActive: Bool {
        defaults.bool(forKey: STTDefaultResolver.automaticParakeetKey)
    }

    /// Call once at launch, after `STTDefaultResolver.adoptParakeetIfDefault`.
    func launch(selected: STTProviderID) {
        guard isActive, selected == .parakeet else { return }
        if model.isInstalled {
            finish()
            return
        }
        guard !firedThisLaunch else { return }
        guard let constrained = networkIsConstrained else {
            launchWaitingForNetworkStatus = true
            return
        }
        firedThisLaunch = true
        if constrained {
            model.pauseForNetwork()
        } else {
            start()
        }
    }

    /// `NWPathMonitor` reported: `constrained` is Low Data Mode or an
    /// expensive interface (a phone hotspot, say).
    func networkChanged(constrained: Bool) {
        networkIsConstrained = constrained
        if launchWaitingForNetworkStatus {
            launchWaitingForNetworkStatus = false
            launch(selected: .parakeet)
            return
        }
        guard firedThisLaunch, isActive, !model.isInstalled else { return }
        if constrained {
            if model.isDownloading, model.isAutomaticDownload { model.pauseForNetwork() }
        } else if model.downloadState == .waitingForNetwork {
            start()
        }
    }

    /// The user picked a speech provider.
    func selectionChanged(to provider: STTProviderID) {
        guard provider != .parakeet else { return }
        launchWaitingForNetworkStatus = false
        if (model.isDownloading && model.isAutomaticDownload) || model.downloadState == .waitingForNetwork {
            model.cancelAutomaticDownload()
        }
        finish()
    }

    /// The user cancelled the download or deleted the model.
    func userStopped() {
        launchWaitingForNetworkStatus = false
        finish()
    }

    /// The model finished downloading.
    func installed() {
        finish()
    }

    private func start() {
        startCount += 1
        model.download(priority: .utility, automatic: true)
    }

    private func finish() {
        defaults.removeObject(forKey: STTDefaultResolver.automaticParakeetKey)
    }
}

// MARK: - Copy

/// The one-line model status shown in onboarding, Get started and the
/// Providers panel while Apple fills in for Parakeet.
enum ParakeetDownloadCopy {
    static func line(for state: ParakeetModelManager.DownloadState) -> String? {
        switch state {
        case .installed:
            return nil
        case let .downloading(fraction, isPreparing):
            return isPreparing
                ? "Preparing the on-device speech model"
                : "Downloading the on-device speech model \u{00B7} \(Int(fraction * 100))%"
        case .waitingForNetwork:
            return "Waiting for Wi-Fi to download the on-device speech model"
        case .failed:
            return "Couldn't download the on-device speech model"
        case .notDownloaded:
            return "The on-device speech model isn't downloaded"
        }
    }

    /// Why dictation still works while the model is missing.
    static let fallbackNote = "Apple's on-device recognition transcribes until then, and Whispur switches to Parakeet by itself."
}
