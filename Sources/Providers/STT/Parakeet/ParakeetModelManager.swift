import FluidAudio
import Foundation
import os

private let logger = Logger(subsystem: "ai.sophiie.whispur", category: "Parakeet")

/// Downloads, deletes and warms the Parakeet model, and publishes where each
/// of those stands for Settings.
@MainActor
final class ParakeetModelManager: ObservableObject, ParakeetModelDownloading {
    static let shared = ParakeetModelManager()

    enum DownloadState: Equatable {
        case notDownloaded
        /// `fraction` covers the download only, 0...1. `isPreparing` is the
        /// tail where macOS compiles the model for the Neural Engine.
        case downloading(fraction: Double, isPreparing: Bool)
        case failed(String)
        case installed(bytesOnDisk: Int64)
        /// An automatic download held back on a metered or Low Data Mode
        /// network. Partial files stay and resume.
        case waitingForNetwork
    }

    enum LoadState: Equatable {
        case unloaded
        case loading
        case loaded(ParakeetEngine.LoadReport)
        case failed(String)
    }

    @Published private(set) var downloadState: DownloadState = .notDownloaded
    @Published private(set) var loadState: LoadState = .unloaded
    /// The running download was started automatically, not by the user.
    private(set) var isAutomaticDownload = false

    let spec: ParakeetModelSpec
    private let modelsDirectory: URL
    private let engine: ParakeetEngine
    private var downloadTask: Task<Void, Never>?
    /// Bumped per download so a cancelled attempt finishing late can't
    /// overwrite the state of the one that replaced it.
    private var downloadGeneration = 0
    private var warmTask: Task<Void, Never>?
    /// Runs after a download finishes, so the app can warm the model when
    /// Parakeet is the selected provider.
    var onInstalled: (() -> Void)?
    /// Runs when the user cancels the download or deletes the model.
    var onUserStopped: (() -> Void)?

    init(
        spec: ParakeetModelSpec = .current,
        modelsDirectory: URL = ParakeetModelLocation.modelsDirectory,
        engine: ParakeetEngine = .shared
    ) {
        self.spec = spec
        self.modelsDirectory = modelsDirectory
        self.engine = engine
        refresh()
    }

    var isInstalled: Bool {
        if case .installed = downloadState { return true }
        return false
    }

    var isDownloading: Bool {
        if case .downloading = downloadState { return true }
        return false
    }

    /// Re-reads the disk. Leaves a running download alone.
    func refresh() {
        guard !isDownloading else { return }
        if ParakeetModelLocation.isInstalled(spec, in: modelsDirectory) {
            downloadState = .installed(bytesOnDisk: ParakeetModelLocation.bytesOnDisk(spec, in: modelsDirectory))
        } else if case .failed = downloadState {
            // Keep the error on screen until the user retries.
        } else if downloadState == .waitingForNetwork {
            // Still waiting; the network monitor resumes it.
        } else {
            downloadState = .notDownloaded
        }
    }

    /// Starts the download. Files already on disk (a finished file from a
    /// cancelled attempt, say) are checked against their Hugging Face
    /// checksums and kept; partial files resume.
    ///
    /// - Parameters:
    ///   - priority: The download task's priority. Automatic downloads run
    ///     at `.utility` so they never compete with dictation.
    ///   - automatic: Started by Whispur rather than the user. Only
    ///     automatic downloads pause on a metered network.
    func download(priority: TaskPriority? = nil, automatic: Bool = false) {
        guard !isDownloading else { return }
        if ParakeetModelLocation.isInstalled(spec, in: modelsDirectory) {
            if downloadState == .waitingForNetwork { downloadState = .notDownloaded }
            refresh()
            return
        }
        isAutomaticDownload = automatic
        downloadState = .downloading(fraction: 0, isPreparing: false)
        downloadGeneration += 1
        let generation = downloadGeneration
        let spec = spec
        let modelsDirectory = modelsDirectory
        let target = ParakeetModelLocation.directory(for: spec, in: modelsDirectory)
        let progress = DownloadProgressTracker()
        let onProgress: ProgressHandler = { [weak self] update in
            let (fraction, isPreparing) = progress.record(update)
            Task { @MainActor in
                guard let self, self.downloadGeneration == generation, self.isDownloading else { return }
                self.downloadState = .downloading(fraction: fraction, isPreparing: isPreparing)
            }
        }
        downloadTask = Task(priority: priority) { [weak self] in
            do {
                try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
                try await AsrModels.download(to: target, version: spec.version, progressHandler: onProgress)
                try Task.checkCancellation()
                guard let self, self.downloadGeneration == generation else { return }
                self.downloadTask = nil
                self.isAutomaticDownload = false
                self.downloadState = .notDownloaded
                self.refresh()
                logger.info("Downloaded \(spec.displayName, privacy: .public)")
                if self.isInstalled { self.onInstalled?() }
            } catch {
                guard let self, self.downloadGeneration == generation else { return }
                self.downloadTask = nil
                self.isAutomaticDownload = false
                if error is CancellationError || Task.isCancelled || (error as? URLError)?.code == .cancelled {
                    self.downloadState = .notDownloaded
                    self.refresh()
                } else {
                    logger.error("Download failed: \(error.localizedDescription, privacy: .public)")
                    self.downloadState = .failed(Self.describe(error))
                }
            }
        }
    }

    /// The user's Cancel.
    func cancelDownload() {
        stopDownload()
        onUserStopped?()
    }

    /// Cancels an automatic download without counting as the user's Cancel.
    func cancelAutomaticDownload() {
        stopDownload()
    }

    /// Stops an automatic download, or holds back one that hasn't started,
    /// until the network is unmetered. A download the user started keeps
    /// going.
    func pauseForNetwork() {
        guard !isInstalled else { return }
        if isDownloading {
            guard isAutomaticDownload else { return }
            stopDownload()
        }
        downloadState = .waitingForNetwork
    }

    private func stopDownload() {
        downloadGeneration += 1
        downloadTask?.cancel()
        downloadTask = nil
        isAutomaticDownload = false
        downloadState = .notDownloaded
        refresh()
    }

    /// Removes the model from disk and memory.
    func delete() async {
        stopDownload()
        onUserStopped?()
        warmTask?.cancel()
        warmTask = nil
        await engine.unload()
        loadState = .unloaded
        do {
            let directory = ParakeetModelLocation.directory(for: spec, in: modelsDirectory)
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
        } catch {
            logger.error("Delete failed: \(error.localizedDescription, privacy: .public)")
            downloadState = .failed("Couldn't delete the model: \(error.localizedDescription)")
            return
        }
        downloadState = .notDownloaded
        refresh()
    }

    /// Loads the model in the background so the first dictation doesn't pay
    /// for it. No-op when it isn't downloaded or is already loaded.
    func warm() {
        guard isInstalled, warmTask == nil else { return }
        if case .loaded = loadState { return }
        loadState = .loading
        let spec = spec
        let directory = modelsDirectory
        let engine = engine
        warmTask = Task(priority: .utility) { [weak self] in
            do {
                let report = try await engine.load(spec, from: directory, priority: .utility)
                await MainActor.run {
                    guard let self else { return }
                    self.warmTask = nil
                    self.loadState = report.map { .loaded($0) } ?? .unloaded
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.warmTask = nil
                    self.loadState = Task.isCancelled ? .unloaded : .failed(error.localizedDescription)
                }
            }
        }
    }

    /// Frees the model's memory (the user picked another provider).
    func unload() {
        warmTask?.cancel()
        warmTask = nil
        loadState = .unloaded
        let engine = engine
        Task { await engine.unload() }
    }

    static func describe(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return "You're offline. Connect to the internet and try again."
            case .timedOut:
                return "The download timed out. Try again."
            default:
                break
            }
        }
        return "The download failed: \(error.localizedDescription)"
    }
}

/// Turns FluidAudio's progress callbacks into one bar that only moves
/// forward. Its download step loads each Core ML bundle in turn and every
/// load reports its own 0...1 run, so the raw fraction jumps back.
final class DownloadProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var highest = 0.0
    private var preparing = false

    func record(_ progress: DownloadProgress) -> (fraction: Double, isPreparing: Bool) {
        lock.lock()
        defer { lock.unlock() }
        switch progress.phase {
        case .listing:
            break
        case .downloading:
            // The download is the first half of each run; the rest compiles.
            highest = max(highest, min(progress.fractionCompleted / 0.5, 1))
        case .compiling:
            highest = 1
            preparing = true
        }
        return (highest, preparing)
    }
}
