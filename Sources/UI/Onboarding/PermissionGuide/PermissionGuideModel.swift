import AppKit
import CoreGraphics
import Foundation

/// A Privacy & Security permission the guide can walk the user through.
enum GuidedPermission: String, CaseIterable, Sendable {
    case accessibility
    case microphone

    /// The anchor of this permission's list in System Settings' Privacy &
    /// Security pane.
    var paneAnchor: String {
        switch self {
        case .accessibility: return "Privacy_Accessibility"
        case .microphone: return "Privacy_Microphone"
        }
    }

    /// Opens System Settings straight at this permission's list.
    var settingsURL: URL {
        // Force-unwrap is safe: the string is a fixed, valid URL.
        URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(paneAnchor)")!
    }

    /// Whether the app tile can be dragged into the list. The Microphone list
    /// only holds apps that asked, so a refused microphone is switched on in
    /// place rather than dragged in.
    var isDraggable: Bool { self == .accessibility }

    /// What System Settings calls the list on the given macOS major version.
    /// macOS 27 renamed the Accessibility list.
    static func listName(_ permission: GuidedPermission, macOSMajor: Int) -> String {
        switch permission {
        case .accessibility:
            return macOSMajor >= 27 ? "Device Control and Data Access" : "Accessibility"
        case .microphone:
            return "Microphone"
        }
    }

    /// The list name on the running macOS.
    var listName: String {
        Self.listName(self, macOSMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
    }

    /// The one-line instruction the guide shows.
    func instruction(appName: String) -> String {
        isDraggable
            ? "Drag \(appName) into the list, then switch it on."
            : "Switch on \(appName) in the \(listName) list."
    }
}

// MARK: - Finding the System Settings window

/// Pure geometry for finding System Settings and docking the guide beside
/// it. Kept free of AppKit state so it can be unit tested.
enum SettingsWindowGeometry {
    static let ownerNames: Set<String> = ["System Settings", "System Preferences"]
    static let minimumSize = CGSize(width: 300, height: 200)

    /// The System Settings main window among `CGWindowListCopyWindowInfo`
    /// entries, in Quartz coordinates (origin top-left of the primary
    /// screen): the largest normal-layer window at least 300×200.
    static func settingsWindowFrame(in windows: [[String: Any]]) -> CGRect? {
        var best: CGRect?
        for window in windows {
            guard let owner = window[kCGWindowOwnerName as String] as? String,
                  ownerNames.contains(owner) else { continue }
            guard (window[kCGWindowLayer as String] as? Int) == 0 else { continue }
            guard let boundsDict = window[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { continue }
            guard frame.width >= minimumSize.width, frame.height >= minimumSize.height else { continue }
            if let current = best, current.width * current.height >= frame.width * frame.height { continue }
            best = frame
        }
        return best
    }

    /// Converts a Quartz rect (top-left origin, y down) to AppKit screen
    /// coordinates (bottom-left origin of the primary screen, y up).
    static func appKitFrame(fromQuartz frame: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(
            x: frame.origin.x,
            y: primaryScreenHeight - frame.origin.y - frame.height,
            width: frame.width,
            height: frame.height
        )
    }

    /// The screen (by index) that shows most of `frame`, so the guide lands
    /// on the System Settings window's display.
    static func screenIndex(for frame: CGRect, screenFrames: [CGRect]) -> Int? {
        var bestIndex: Int?
        var bestArea: CGFloat = 0
        for (index, screen) in screenFrames.enumerated() {
            let overlap = screen.intersection(frame)
            guard !overlap.isNull else { continue }
            let area = overlap.width * overlap.height
            if area > bestArea {
                bestArea = area
                bestIndex = index
            }
        }
        return bestIndex
    }

    static let gap: CGFloat = 12
    static let margin: CGFloat = 8

    /// Where the guide's origin goes: centred under the System Settings
    /// window when there is room on its screen, otherwise tucked inside its
    /// bottom edge. Always clamped to the visible frame.
    static func guideOrigin(settings: CGRect, guideSize: CGSize, visible: CGRect) -> CGPoint {
        var x = settings.midX - guideSize.width / 2
        var y = settings.minY - gap - guideSize.height
        if y < visible.minY + margin {
            // No room below: overlap the window's bottom edge.
            y = settings.minY + 16
        }
        x = min(max(x, visible.minX + margin), visible.maxX - guideSize.width - margin)
        y = min(max(y, visible.minY + margin), visible.maxY - guideSize.height - margin)
        return CGPoint(x: x, y: y)
    }
}

// MARK: - State machine

/// How a guide session ended.
enum PermissionGuideOutcome: Equatable, Sendable {
    case granted
    case settingsClosed
    case timedOut
    case cancelled
}

/// The guide's lifecycle: `opening` (waiting for System Settings to show a
/// window) → `guiding` (docked beside it) → `finished`. Pure: the controller
/// feeds it the clock, the grant and the window frame on every tick.
struct PermissionGuideMachine: Equatable {
    enum Phase: Equatable {
        case idle
        case opening(since: TimeInterval)
        case guiding(missingSince: TimeInterval?)
        case finished(PermissionGuideOutcome)
    }

    enum Action: Equatable {
        case none
        /// Dock the guide beside this System Settings frame (AppKit coords).
        case dock(CGRect)
        case finish(PermissionGuideOutcome)
    }

    /// How long System Settings gets to show a window before the guide gives up.
    static let openingTimeout: TimeInterval = 15
    /// A window that vanishes for this long counts as closed (pane switches
    /// can drop it from the window list for a frame).
    static let closeGrace: TimeInterval = 0.4

    private(set) var phase: Phase = .idle

    var isActive: Bool {
        switch phase {
        case .opening, .guiding: return true
        case .idle, .finished: return false
        }
    }

    mutating func start(now: TimeInterval) {
        phase = .opening(since: now)
    }

    mutating func cancel() {
        guard isActive else { return }
        phase = .finished(.cancelled)
    }

    mutating func tick(now: TimeInterval, granted: Bool, settingsFrame: CGRect?) -> Action {
        switch phase {
        case .idle, .finished:
            return .none
        case .opening(let since):
            if granted { return finish(.granted) }
            if let frame = settingsFrame {
                phase = .guiding(missingSince: nil)
                return .dock(frame)
            }
            if now - since >= Self.openingTimeout { return finish(.timedOut) }
            return .none
        case .guiding(let missingSince):
            if granted { return finish(.granted) }
            if let frame = settingsFrame {
                phase = .guiding(missingSince: nil)
                return .dock(frame)
            }
            guard let missingSince else {
                phase = .guiding(missingSince: now)
                return .none
            }
            return now - missingSince >= Self.closeGrace ? finish(.settingsClosed) : .none
        }
    }

    private mutating func finish(_ outcome: PermissionGuideOutcome) -> Action {
        phase = .finished(outcome)
        return .finish(outcome)
    }
}

// MARK: - The app as System Settings lists it

enum PermissionGuideApp {
    /// The running `.app` bundle, or nil for a bare development binary
    /// (which has no bundle to drag, so it gets the pane alone).
    static func bundleURL(_ bundle: Bundle = .main) -> URL? {
        let url = bundle.bundleURL.standardizedFileURL
        return url.pathExtension.lowercased() == "app" ? url : nil
    }

    /// The name System Settings lists the app under.
    static func displayName(for bundleURL: URL?) -> String {
        guard let bundleURL else { return "Whispur" }
        var name = FileManager.default.displayName(atPath: bundleURL.path)
        if (name as NSString).pathExtension.lowercased() == "app" {
            name = (name as NSString).deletingPathExtension
        }
        return name.isEmpty ? "Whispur" : name
    }
}
