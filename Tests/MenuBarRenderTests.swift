import AppKit
import SwiftUI
import XCTest
@testable import Whispur

/// Renders the menu bar panel to PNG for visual review. Skipped unless
/// `WHISPUR_RENDER_MENUBAR` is set (pass `TEST_RUNNER_WHISPUR_RENDER_MENUBAR=1`
/// to xcodebuild). Output goes to `WHISPUR_RENDER_DIR`, default
/// /tmp/whispur-menubar-render, with file names prefixed by
/// `WHISPUR_RENDER_PREFIX` (default "menubar").
///
/// Uses scratch history and stats like `SettingsRenderTests`; the one
/// standard-defaults value it sets (the setup guide switch) is put back.
@MainActor
final class MenuBarRenderTests: XCTestCase {
    func testRenderMenuBarPanel() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["WHISPUR_RENDER_MENUBAR"] != nil, "Set WHISPUR_RENDER_MENUBAR to render the menu bar panel")
        let dir = URL(fileURLWithPath: env["WHISPUR_RENDER_DIR"] ?? "/tmp/whispur-menubar-render")
        let prefix = env["WHISPUR_RENDER_PREFIX"] ?? "menubar"
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("whispur-menubar-render-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let suite = "ai.sophiie.whispur.render.menubar"
        let vocabularyDefaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        vocabularyDefaults.removePersistentDomain(forName: suite)
        defer { vocabularyDefaults.removePersistentDomain(forName: suite) }

        let setupKey = "showSetupGuide"
        let savedSetup = UserDefaults.standard.object(forKey: setupKey)
        defer {
            if let savedSetup { UserDefaults.standard.set(savedSetup, forKey: setupKey) } else { UserDefaults.standard.removeObject(forKey: setupKey) }
        }

        let base = try SettingsRenderTests.makeAppState(in: scratch, vocabularyDefaults: vocabularyDefaults)
        let busy = try Self.makeAppState(base: base, statsURL: Self.writeStats(in: scratch, name: "busy.json", week: [0, 0, 0, 2400, 1900, 420, 380]))
        let fresh = try Self.makeAppState(base: base, statsURL: Self.writeStats(in: scratch, name: "fresh.json", week: []))

        let last = PipelineResult(
            rawTranscript: "for the slack agent standup we need to use a single thread for every update",
            cleanedText: "For the Slack agent standup we need to use a single thread for every update, so the channel stays readable.",
            sttProvider: .parakeet,
            llmProvider: .groq,
            llmModel: "openai/gpt-oss-20b",
            timestamp: Date()
        )

        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .dark ? "dark" : "light"

            // Ready, with a week of stats and a last transcript.
            busy.setMicrophoneAccessForRendering(true)
            busy.hotkeyManager.setAccessibilityForRendering(.on)
            busy.pipeline.setLastResultForRendering(last)
            busy.pipeline.setPhaseForRendering(.idle)
            try render(MenuBarView(appState: busy), scheme: scheme, to: dir.appendingPathComponent("\(prefix)-idle-\(suffix).png"))

            // Recording: the action card turns into the stop control.
            busy.pipeline.setPhaseForRendering(.recording)
            try render(MenuBarView(appState: busy), scheme: scheme, to: dir.appendingPathComponent("\(prefix)-recording-\(suffix).png"))

            // A failed dictation.
            busy.pipeline.setPhaseForRendering(.error("Groq Whisper transcription timed out."))
            try render(MenuBarView(appState: busy), scheme: scheme, to: dir.appendingPathComponent("\(prefix)-error-\(suffix).png"))
            busy.pipeline.setPhaseForRendering(.idle)

            // First run: no stats, permissions missing, setup guide on.
            UserDefaults.standard.set(true, forKey: setupKey)
            fresh.setMicrophoneAccessForRendering(false)
            fresh.hotkeyManager.setAccessibilityForRendering(.off)
            fresh.pipeline.setLastResultForRendering(nil)
            try render(MenuBarView(appState: fresh), scheme: scheme, to: dir.appendingPathComponent("\(prefix)-needs-setup-\(suffix).png"))
            if let savedSetup { UserDefaults.standard.set(savedSetup, forKey: setupKey) } else { UserDefaults.standard.removeObject(forKey: setupKey) }
        }
    }

    // MARK: - Fixtures

    /// An app state sharing `base`'s scratch stores, with its own stats.
    private static func makeAppState(base: AppState, statsURL: URL) throws -> AppState {
        AppState(
            historyStore: base.historyStore,
            stats: DictationStats(fileURL: statsURL),
            providerRequestLog: base.providerRequestLog,
            vocabulary: base.vocabulary,
            styles: base.styles,
            evalCases: base.evalCases,
            startsServices: false
        )
    }

    /// Writes a stats file whose last seven days (oldest first) hold `week`.
    private static func writeStats(in scratch: URL, name: String, week: [Int]) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        var daily: [String: Int] = [:]
        for (index, words) in week.enumerated() where words > 0 {
            let date = Calendar.current.date(byAdding: .day, value: index - (week.count - 1), to: Date()) ?? Date()
            daily[formatter.string(from: date)] = words
        }
        // Older days make up the rest of the total.
        let total = week.isEmpty ? 0 : 18_364
        let json: [String: Any] = ["totalWords": total, "dailyWords": daily, "totalDictations": week.isEmpty ? 0 : 1284]
        let url = scratch.appendingPathComponent(name)
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        return url
    }

    // MARK: - Rendering

    /// Renders at the panel's natural height, like the menu bar window.
    private func render<V: View>(_ view: V, scheme: ColorScheme, to url: URL) throws {
        let measuring = NSHostingView(rootView: view.environment(\.colorScheme, scheme))
        measuring.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        let size = measuring.fittingSize
        try SettingsRenderTests.renderPNG(view, scheme: scheme, size: CGSize(width: ceil(size.width), height: ceil(size.height)), to: url)
    }
}
