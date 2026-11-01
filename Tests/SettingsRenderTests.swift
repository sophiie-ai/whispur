import AppKit
import SwiftUI
import XCTest
@testable import Whispur

/// Renders the Settings window to PNG for visual review. Skipped unless
/// `WHISPUR_RENDER_SETTINGS` is set (pass `TEST_RUNNER_WHISPUR_RENDER_SETTINGS=1`
/// to xcodebuild). Output goes to `WHISPUR_RENDER_DIR`, default
/// /tmp/whispur-settings-build/render.
///
/// Uses scratch history, stats, keys and page selection, so nothing from the
/// real app state is read for the rendered data or written back.
@MainActor
final class SettingsRenderTests: XCTestCase {
    private static let size = CGSize(width: 1000, height: 760)

    func testRenderSettingsPages() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["WHISPUR_RENDER_SETTINGS"] != nil, "Set WHISPUR_RENDER_SETTINGS to render Settings")
        let dir = URL(fileURLWithPath: env["WHISPUR_RENDER_DIR"] ?? "/tmp/whispur-settings-build/render")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("whispur-render-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let appState = try Self.makeAppState(in: scratch)
        let secrets = InMemorySecretStore()
        for key in KeychainKey.allCases {
            secrets.values[key] = key == .awsRegion ? "us-east-1" : "sk-render-0000000000abcd"
        }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "ai.sophiie.whispur.render"))
        defer { defaults.removePersistentDomain(forName: "ai.sophiie.whispur.render") }

        let ready = SettingsView.PermissionsOverride(microphone: true, accessibility: true)
        let missing = SettingsView.PermissionsOverride(microphone: true, accessibility: false)

        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .dark ? "dark" : "light"
            for tab in SettingsTab.visible {
                defaults.set(tab.rawValue, forKey: SettingsView.selectedTabKey)
                let view = SettingsView(appState: appState, secretStore: secrets, permissionsOverride: ready, defaults: defaults)
                try render(view, scheme: scheme, to: dir.appendingPathComponent("\(tab.rawValue)-\(suffix).png"))
            }
            defaults.set(SettingsTab.dictation.rawValue, forKey: SettingsView.selectedTabKey)
            let needsSetup = SettingsView(appState: appState, secretStore: secrets, permissionsOverride: missing, defaults: defaults)
            try render(needsSetup, scheme: scheme, to: dir.appendingPathComponent("dictation-needs-setup-\(suffix).png"))
        }
    }

    // MARK: - Fixtures

    static let sampleHistory: [(daysAgo: Int, text: String)] = [
        (0, "Can we push the design review to Thursday afternoon so everyone can see the new onboarding flow first?"),
        (0, "Sounds good, ship it."),
        (1, "Remind me to send the updated invoice template to the plumbing team before Friday."),
        (1, "The settings window should open on the dictation page by default instead of setup."),
        (2, "Let's walk through the quarterly roadmap after standup and then split the work into smaller tickets."),
        (3, "Thanks for the quick turnaround on the quote."),
    ]

    private static func makeAppState(in scratch: URL) throws -> AppState {
        let now = Date()
        let items = sampleHistory.map { entry in
            PipelineResult(
                rawTranscript: entry.text.lowercased(),
                cleanedText: entry.text,
                sttProvider: .deepgram,
                llmProvider: .anthropic,
                llmModel: "claude-haiku",
                timestamp: Calendar.current.date(byAdding: .day, value: -entry.daysAgo, to: now) ?? now
            )
        }
        let historyURL = scratch.appendingPathComponent("history.json")
        try JSONEncoder().encode(items).write(to: historyURL)

        let statsURL = scratch.appendingPathComponent("stats.json")
        let stats = #"{"totalWords":18240,"dailyWords":{},"totalDictations":1284}"#
        try Data(stats.utf8).write(to: statsURL)

        return AppState(
            historyStore: PipelineHistoryStore(fileURL: historyURL),
            stats: DictationStats(fileURL: statsURL),
            startsServices: false
        )
    }

    // MARK: - Rendering

    private func render<V: View>(_ view: V, scheme: ColorScheme, to url: URL) throws {
        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        let rect = CGRect(origin: .zero, size: Self.size)
        let host = NSHostingView(rootView: view
            .environment(\.colorScheme, scheme)
            .frame(width: Self.size.width, height: Self.size.height))
        host.frame = rect
        host.appearance = appearance

        let window = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()

        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(Self.size.width * 2),
            pixelsHigh: Int(Self.size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        rep.size = Self.size
        // Resolve dynamic colours against the requested appearance while drawing.
        appearance?.performAsCurrentDrawingAppearance {
            host.cacheDisplay(in: rect, to: rep)
        }
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try data.write(to: url)
    }
}
