import AppKit
import Foundation
import os

private let logger = Logger(subsystem: "ai.sophiie.whispur", category: "ApplicationsFolderMover")

/// Where the running copy of Whispur lives, as far as the first-launch
/// "Move to Applications" check cares.
enum AppInstallLocation: Equatable {
    /// Already in /Applications or ~/Applications: nothing to do.
    case applicationsFolder
    /// A debug, test or build-directory copy: never prompt.
    case developmentBuild
    /// Running straight off a read-only volume, normally the mounted DMG.
    case diskImage(volumePath: String)
    /// Gatekeeper's App Translocation copy; the original is elsewhere.
    case translocated
    /// Anywhere else a user can run it from, e.g. ~/Downloads.
    case elsewhere

    var shouldOfferMove: Bool {
        switch self {
        case .applicationsFolder, .developmentBuild:
            return false
        case .diskImage, .translocated, .elsewhere:
            return true
        }
    }

    /// Classifies a bundle path. Pure, so the allow/block sides are unit
    /// tested; the live caller supplies the translocation and read-only
    /// volume answers from the system.
    static func classify(
        bundlePath: String,
        homeDirectory: String,
        isTranslocated: Bool,
        isOnReadOnlyVolume: Bool
    ) -> AppInstallLocation {
        let path = (bundlePath as NSString).standardizingPath

        if isTranslocated || isTranslocationPath(path) {
            return .translocated
        }
        if !path.hasSuffix(".app") || isBuildDirectory(path) {
            return .developmentBuild
        }

        let parent = (path as NSString).deletingLastPathComponent
        let userApplications = ((homeDirectory as NSString).standardizingPath as NSString)
            .appendingPathComponent("Applications")
        if isInside(parent, folder: "/Applications") || isInside(parent, folder: userApplications) {
            return .applicationsFolder
        }

        if path.hasPrefix("/Volumes/"), isOnReadOnlyVolume {
            let components = (path as NSString).pathComponents
            // ["/", "Volumes", "<name>", ...]
            let volume = components.count >= 3
                ? NSString.path(withComponents: Array(components.prefix(3)))
                : "/Volumes"
            return .diskImage(volumePath: volume)
        }
        return .elsewhere
    }

    /// Gatekeeper runs quarantined apps opened in place from a randomized
    /// read-only mount under /private/var/folders/…/AppTranslocation/.
    static func isTranslocationPath(_ path: String) -> Bool {
        path.contains("/AppTranslocation/")
            && (path.hasPrefix("/private/var/folders/") || path.hasPrefix("/var/folders/"))
    }

    private static func isBuildDirectory(_ path: String) -> Bool {
        let markers = ["/DerivedData/", "/Build/Products/", "/build/", "/.build/"]
        return markers.contains { path.contains($0) }
    }

    /// True for the folder itself and anything nested in it (e.g. a
    /// /Applications/Utilities copy).
    private static func isInside(_ parent: String, folder: String) -> Bool {
        parent == folder || parent.hasPrefix(folder + "/")
    }
}

/// The first-launch "Move to Applications" offer: copies or moves the
/// bundle into the Applications folder, relaunches the new copy (which also
/// leaves App Translocation behind) and quits this one.
@MainActor
enum ApplicationsFolderMover {
    /// `defaults write ai.sophiie.whispur skipMoveToApplications -bool YES`
    /// turns the offer off for good; "Don't ask again" sets it too.
    static let optOutDefaultsKey = "skipMoveToApplications"
    /// Environment opt-out for scripted launches.
    static let optOutEnvironmentKey = "WHISPUR_SKIP_MOVE_TO_APPLICATIONS"

    /// Offers the move when the running copy is outside Applications.
    /// Returns true when Whispur is relaunching from its new home, so the
    /// caller skips onboarding (the new copy shows it).
    @discardableResult
    static func offerMoveIfNeeded(
        bundle: Bundle = .main,
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        #if DEBUG
        return false
        #else
        guard !isOptedOut(defaults: defaults, environment: environment) else { return false }

        let bundleURL = bundle.bundleURL
        let translocated = Translocation.isTranslocated(bundleURL)
        let sourceURL = translocated ? (Translocation.originalURL(of: bundleURL) ?? bundleURL) : bundleURL
        let location = AppInstallLocation.classify(
            bundlePath: bundleURL.path,
            homeDirectory: NSHomeDirectory(),
            isTranslocated: translocated,
            isOnReadOnlyVolume: isReadOnlyVolume(bundleURL)
        )
        guard location.shouldOfferMove else { return false }

        // A translocated copy reports where it really came from: a DMG
        // original is copied, a Downloads original is moved.
        let sourceLocation = translocated
            ? AppInstallLocation.classify(
                bundlePath: sourceURL.path,
                homeDirectory: NSHomeDirectory(),
                isTranslocated: false,
                isOnReadOnlyVolume: isReadOnlyVolume(sourceURL)
            )
            : location

        logger.info("Offering move to Applications from \(sourceURL.path, privacy: .public)")
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Move Whispur to your Applications folder?"
        alert.informativeText = "Whispur works best from Applications: it keeps its permissions and updates itself there."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"

        let response = alert.runModal()
        if alert.suppressionButton?.state == .on {
            defaults.set(true, forKey: optOutDefaultsKey)
        }
        guard response == .alertFirstButtonReturn else { return false }

        // A quarantined copy that already sits in Applications is still
        // translocated; clearing the flag and relaunching in place fixes it.
        if sourceLocation == .applicationsFolder {
            stripQuarantine(sourceURL)
            relaunch(at: sourceURL, thenEject: nil)
            return true
        }

        do {
            let destination = try install(from: sourceURL, copying: !canMove(sourceURL, location: sourceLocation))
            var ejectVolume: String?
            if case let .diskImage(volume) = sourceLocation, askToEject() {
                ejectVolume = volume
            }
            relaunch(at: destination, thenEject: ejectVolume)
            return true
        } catch {
            logger.error("Move to Applications failed: \(error.localizedDescription, privacy: .public)")
            let failure = NSAlert()
            failure.alertStyle = .warning
            failure.messageText = "Couldn't move Whispur"
            failure.informativeText = "\(error.localizedDescription)\n\nYou can drag Whispur into Applications in Finder instead."
            failure.runModal()
            return false
        }
        #endif
    }

    static func isOptedOut(defaults: UserDefaults, environment: [String: String]) -> Bool {
        if defaults.bool(forKey: optOutDefaultsKey) { return true }
        if let value = environment[optOutEnvironmentKey]?.lowercased(), ["1", "true", "yes"].contains(value) {
            return true
        }
        // A unit-test host launch is never a real first run.
        return environment["XCTestConfigurationFilePath"] != nil
    }

    // MARK: - Moving

    private static func canMove(_ source: URL, location: AppInstallLocation) -> Bool {
        if case .diskImage = location { return false }
        return FileManager.default.isWritableFile(atPath: source.deletingLastPathComponent().path)
    }

    private static func applicationsFolder() throws -> URL {
        let system = URL(fileURLWithPath: "/Applications", isDirectory: true)
        if FileManager.default.isWritableFile(atPath: system.path) { return system }
        let user = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        return user
    }

    private static func install(from source: URL, copying: Bool) throws -> URL {
        let fileManager = FileManager.default
        let destination = try applicationsFolder().appendingPathComponent(source.lastPathComponent)

        if fileManager.fileExists(atPath: destination.path) {
            // The existing copy is an older Whispur: quit it, then bin it.
            quitRunningCopy(at: destination)
            try fileManager.trashItem(at: destination, resultingItemURL: nil)
        }

        if copying {
            try fileManager.copyItem(at: source, to: destination)
        } else {
            try fileManager.moveItem(at: source, to: destination)
        }
        stripQuarantine(destination)
        return destination
    }

    private static func quitRunningCopy(at url: URL) {
        let target = url.standardizedFileURL.resolvingSymlinksInPath()
        let current = ProcessInfo.processInfo.processIdentifier
        for app in NSWorkspace.shared.runningApplications
        where app.processIdentifier != current
            && app.bundleURL?.standardizedFileURL.resolvingSymlinksInPath() == target {
            app.terminate()
            let deadline = Date().addingTimeInterval(5)
            while !app.isTerminated, Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            }
            if !app.isTerminated { app.forceTerminate() }
        }
    }

    /// The user just chose to install this copy, so Gatekeeper's quarantine
    /// flag has done its job; clearing it stops the new copy translocating.
    private static func stripQuarantine(_ url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        process.arguments = ["-dr", "com.apple.quarantine", url.path]
        try? process.run()
        process.waitUntilExit()
    }

    private static func askToEject() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Eject the Whispur disk image?"
        alert.informativeText = "Whispur is now in Applications, so the installer disk image isn't needed any more."
        alert.addButton(withTitle: "Eject")
        alert.addButton(withTitle: "Keep It")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func relaunch(at destination: URL, thenEject volume: String?) {
        AppRelauncher.relaunch(at: destination, thenEject: volume)
    }

    private static func isReadOnlyVolume(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) ?? false
    }
}

/// Security.framework's App Translocation queries. They are exported but not
/// in the public headers, so they're looked up at runtime and treated as
/// absent if a future macOS drops them.
private enum Translocation {
    private typealias IsTranslocated = @convention(c) (CFURL, UnsafeMutablePointer<Bool>, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Bool
    private typealias OriginalPath = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?

    private static let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY)

    static func isTranslocated(_ url: URL) -> Bool {
        if AppInstallLocation.isTranslocationPath(url.path) { return true }
        guard let symbol = dlsym(handle, "SecTranslocateIsTranslocatedURL") else { return false }
        let function = unsafeBitCast(symbol, to: IsTranslocated.self)
        var result = false
        return function(url as CFURL, &result, nil) && result
    }

    static func originalURL(of url: URL) -> URL? {
        guard let symbol = dlsym(handle, "SecTranslocateCreateOriginalPathForURL") else { return nil }
        let function = unsafeBitCast(symbol, to: OriginalPath.self)
        return function(url as CFURL, nil)?.takeRetainedValue() as URL?
    }
}
