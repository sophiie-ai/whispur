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
    /// Tall enough to show every section of the scrolling pages.
    private static let tallSize = CGSize(width: 1000, height: 1900)
    /// Scrolling pages that also get a tall render.
    private static let tallTabs: [SettingsTab] = [.providers, .preferences, .getStarted, .styles]

    func testRenderSettingsPages() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["WHISPUR_RENDER_SETTINGS"] != nil, "Set WHISPUR_RENDER_SETTINGS to render Settings")
        let dir = URL(fileURLWithPath: env["WHISPUR_RENDER_DIR"] ?? "/tmp/whispur-settings-build/render")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("whispur-render-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let vocabularyDefaults = try XCTUnwrap(UserDefaults(suiteName: "ai.sophiie.whispur.render.vocabulary"))
        vocabularyDefaults.removePersistentDomain(forName: "ai.sophiie.whispur.render.vocabulary")
        defer { vocabularyDefaults.removePersistentDomain(forName: "ai.sophiie.whispur.render.vocabulary") }
        let appState = try Self.makeAppState(in: scratch, vocabularyDefaults: vocabularyDefaults)
        let secrets = InMemorySecretStore()
        for key in KeychainKey.allCases {
            secrets.values[key] = key == .awsRegion ? "us-east-1" : "sk-render-0000000000abcd"
        }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "ai.sophiie.whispur.render"))
        defer { defaults.removePersistentDomain(forName: "ai.sophiie.whispur.render") }

        // Select the longest sample device so the Input device row shows its
        // worst case. The preference lives in the standard defaults, so put
        // the real value back afterwards.
        let inputKey = "preferredAudioInputUID"
        let savedInput = UserDefaults.standard.object(forKey: inputKey)
        defer {
            if let savedInput { UserDefaults.standard.set(savedInput, forKey: inputKey) } else { UserDefaults.standard.removeObject(forKey: inputKey) }
        }
        appState.preferredAudioInputUID = Self.sampleInputDevices[1].uid
        // Show "Languages I speak" with two languages chosen; same save and
        // restore as above.
        let languagesKey = AppState.spokenLanguagesKey
        let savedLanguages = UserDefaults.standard.object(forKey: languagesKey)
        defer {
            if let savedLanguages { UserDefaults.standard.set(savedLanguages, forKey: languagesKey) } else { UserDefaults.standard.removeObject(forKey: languagesKey) }
        }
        appState.sttLanguageSelection = STTLanguageSelection(codes: ["en-US", "es-MX"])
        let devices = Self.sampleInputDevices

        let ready = SettingsView.PermissionsOverride(microphone: true, accessibility: true)
        let missing = SettingsView.PermissionsOverride(microphone: true, accessibility: false)

        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .dark ? "dark" : "light"
            for tab in SettingsTab.visible {
                defaults.set(tab.rawValue, forKey: SettingsView.selectedTabKey)
                let view = SettingsView(appState: appState, secretStore: secrets, permissionsOverride: ready, defaults: defaults)
                    .environment(\.listInputDevices) { devices }
                try render(view, scheme: scheme, to: dir.appendingPathComponent("\(tab.rawValue)-\(suffix).png"))
                if Self.tallTabs.contains(tab) {
                    try render(view, scheme: scheme, size: Self.tallSize, to: dir.appendingPathComponent("\(tab.rawValue)-full-\(suffix).png"))
                }
            }
            if let failed = appState.historyStore.items.first(where: { appState.historyStore.canRetry($0) }) {
                defaults.set(SettingsTab.activity.rawValue, forKey: SettingsView.selectedTabKey)
                appState.retrier.setStateForRendering(running: [failed.id], toast: "Copied to clipboard")
                let retrying = SettingsView(appState: appState, secretStore: secrets, permissionsOverride: ready, defaults: defaults)
                try render(retrying, scheme: scheme, to: dir.appendingPathComponent("activity-retrying-\(suffix).png"))
                appState.retrier.setStateForRendering(running: [], toast: nil)
            }
            // Activity with a dictation expanded (Mark as wrong, Used raw,
            // one already marked), and the Mark as wrong sheet.
            let succeeded = appState.historyStore.items.filter { !$0.isFailed && $0.failure == nil }
            if let open = succeeded.first {
                let activity = ActivitySettingsView(
                    historyStore: appState.historyStore,
                    retrier: appState.retrier,
                    evalCases: appState.evalCases,
                    initiallyExpanded: open.id,
                    onRetry: { _ in }
                )
                .background(SophiieTheme.Palette.surfaceWarm)
                try render(activity, scheme: scheme, size: CGSize(width: 1000, height: 1400), to: dir.appendingPathComponent("activity-expanded-\(suffix).png"))
                let sheet = MarkAsWrongSheet(item: open, onSave: { _, _ in }, onCancel: {})
                try render(sheet, scheme: scheme, size: CGSize(width: 520, height: 600), to: dir.appendingPathComponent("activity-mark-wrong-sheet-\(suffix).png"))
            }
            defaults.set(SettingsTab.dictation.rawValue, forKey: SettingsView.selectedTabKey)
            let needsSetup = SettingsView(appState: appState, secretStore: secrets, permissionsOverride: missing, defaults: defaults)
            try render(needsSetup, scheme: scheme, to: dir.appendingPathComponent("dictation-needs-setup-\(suffix).png"))
        }
    }

    // MARK: - Fixtures

    static let sampleInputDevices: [AudioDevice] = [
        AudioDevice(id: 1, name: "MacBook Pro Microphone", uid: "render-builtin"),
        AudioDevice(id: 2, name: "MacBook Pro Microphone (Built-in) — Studio Display Camera Array", uid: "render-long"),
        AudioDevice(id: 3, name: "AirPods Pro", uid: "render-airpods"),
    ]

    static let sampleHistory: [(daysAgo: Int, text: String)] = [
        (0, "Can we push the design review to Thursday afternoon so everyone can see the new onboarding flow first?"),
        (0, "Sounds good, ship it."),
        (1, "Remind me to send the updated invoice template to the plumbing team before Friday."),
        (1, "The settings window should open on the dictation page by default instead of setup."),
        (2, "Let's walk through the quarterly roadmap after standup and then split the work into smaller tickets."),
        (3, "Thanks for the quick turnaround on the quote."),
    ]

    static let sampleRequests: [(provider: String, kind: ProviderRequestKind, url: String, status: Int?)] = [
        ("deepgram", .stt, "https://api.deepgram.com/v1/listen", 200),
        ("anthropic", .llm, "https://api.anthropic.com/v1/messages", 200),
        ("deepgram", .stt, "https://api.deepgram.com/v1/listen", 200),
        ("anthropic", .llm, "https://api.anthropic.com/v1/messages", 429),
        ("deepgram", .stt, "https://api.deepgram.com/v1/listen", 200),
        ("groqWhisper", .stt, ProviderHTTPClient.scriptGuardMethod, nil),
    ]

    static let sampleTerms: [(text: String, learnedFrom: String?)] = [
        ("Brisbane CBD", nil),
        ("ElevenLabs", "eleven labs"),
        ("TanStack Router", nil),
        ("PlanetScale", nil),
        ("kubectl", "cube cuddle"),
        ("SwiftUI", nil),
        ("Sophiie", "Sophie"),
        ("Whispur", nil),
    ]

    static func makeAppState(in scratch: URL, vocabularyDefaults: UserDefaults) throws -> AppState {
        let now = Date()
        // Seed the old plain list so the migration path runs, then add the
        // learned terms on top.
        vocabularyDefaults.set(
            sampleTerms.filter { $0.learnedFrom == nil }.reversed().map(\.text).joined(separator: "\n"),
            forKey: VocabularyStore.legacyKey
        )
        let vocabulary = VocabularyStore(defaults: vocabularyDefaults)
        vocabularyDefaults.removeObject(forKey: StyleStore.key)
        let styles = StyleStore(defaults: vocabularyDefaults, hasCustomPrompt: false)
        styles.setOverride(bundleID: "com.apple.Safari", name: "Safari", style: .formal)
        styles.setOverride(bundleID: "com.apple.TextEdit", name: "TextEdit", style: .verbatim)
        for (index, term) in sampleTerms.enumerated().reversed() {
            guard let original = term.learnedFrom else { continue }
            vocabulary.add(term.text, source: .learned(original: original), at: now.addingTimeInterval(Double(-index) * 86_400))
        }
        var items = sampleHistory.map { entry in
            PipelineResult(
                rawTranscript: entry.text.lowercased(),
                cleanedText: entry.text,
                sttProvider: .deepgram,
                llmProvider: .anthropic,
                llmModel: "claude-haiku",
                timestamp: Calendar.current.date(byAdding: .day, value: -entry.daysAgo, to: now) ?? now
            )
        }
        // The newest one went through "Use raw", with a raw transcript that
        // reads like real speech.
        items[0].rawTranscript = "um can we push the design review to thursday afternoon so everyone can see the new onboarding flow first"
        items[0].usedRawAt = now
        // One marked as wrong already.
        let evalCases = MyEvalCaseStore(fileURL: scratch.appendingPathComponent("MyEvalCases.jsonl"))
        evalCases.append(MyEvalCase(
            id: MyEvalCase.makeID(dictationID: items[2].id, at: now),
            input: items[2].rawTranscript, expected: items[2].cleanedText, vocabulary: [], tags: [.other]
        ))
        let historyURL = scratch.appendingPathComponent("history.json")
        try JSONEncoder().encode(items).write(to: historyURL)
        // One failed dictation with its recording kept, one whose recording
        // expired, and one that was retried.
        let renderHistory = PipelineHistoryStore(fileURL: historyURL)
        let wav = scratch.appendingPathComponent("failed.wav")
        try Data(repeating: 0, count: 64).write(to: wav)
        renderHistory.recordFailure(
            error: "Groq Whisper error (503): Service unavailable.",
            wavURL: nil,
            sttProvider: .groqWhisper, llmProvider: .groq, appBundleID: "com.apple.mail", style: .formal,
            at: now.addingTimeInterval(-2 * 86_400)
        )
        let retried = renderHistory.recordFailure(
            error: "Groq Whisper transcription timed out.",
            wavURL: nil,
            sttProvider: .groqWhisper, llmProvider: .groq, appBundleID: nil, style: nil,
            at: now.addingTimeInterval(-3600)
        )
        renderHistory.markRetried(retried.id, rawTranscript: "hola que tal", text: "Hola, ¿qué tal?", llmModel: "openai/gpt-oss-20b", style: .standard)
        renderHistory.recordFailure(
            error: "Groq Whisper transcription timed out.",
            wavURL: wav,
            sttProvider: .groqWhisper, llmProvider: .groq, appBundleID: "com.tinyspeck.slackmacgap", style: .casual,
            at: now.addingTimeInterval(-120)
        )

        let statsURL = scratch.appendingPathComponent("stats.json")
        let stats = #"{"totalWords":18240,"dailyWords":{},"totalDictations":1284}"#
        try Data(stats.utf8).write(to: statsURL)

        let requestLog = ProviderRequestLog(fileURL: scratch.appendingPathComponent("provider-requests.json"))
        for (index, entry) in sampleRequests.enumerated() {
            if entry.url == ProviderHTTPClient.scriptGuardMethod {
                requestLog.record(ProviderRequestLogEntry(
                    id: UUID(),
                    timestamp: now.addingTimeInterval(Double(index - sampleRequests.count) * 90),
                    providerID: entry.provider,
                    kind: entry.kind,
                    endpointURL: "Transcript in an unexpected script, re-ran per language",
                    httpMethod: ProviderHTTPClient.scriptGuardMethod,
                    statusCode: nil,
                    durationMS: 0,
                    requestSummary: "Script guard: the transcript used arabic letters (6 of 6), which none of your languages use.",
                    responseBodyPreview: "Hola, qué tal.",
                    errorMessage: nil
                ))
                continue
            }
            requestLog.record(ProviderRequestLogEntry(
                id: UUID(),
                timestamp: now.addingTimeInterval(Double(index - sampleRequests.count) * 90),
                providerID: entry.provider,
                kind: entry.kind,
                endpointURL: entry.url,
                httpMethod: "POST",
                statusCode: entry.status,
                durationMS: 300 + index * 70,
                requestSummary: "POST \(entry.url)\n\nHeaders:\nAuthorization: <redacted>",
                responseBodyPreview: entry.status == 200 ? #"{"text":"Sounds good, ship it."}"# : #"{"error":"rate limited"}"#,
                errorMessage: entry.status == 200 ? nil : "Rate limited. Try again shortly."
            ))
        }

        return AppState(
            historyStore: renderHistory,
            stats: DictationStats(fileURL: statsURL),
            providerRequestLog: requestLog,
            vocabulary: vocabulary,
            styles: styles,
            evalCases: evalCases,
            startsServices: false
        )
    }

    // MARK: - Rendering

    private func render<V: View>(_ view: V, scheme: ColorScheme, size: CGSize = SettingsRenderTests.size, to url: URL) throws {
        try Self.renderPNG(view, scheme: scheme, size: size, to: url)
    }

    /// Draws `view` at `size` in `scheme` and writes a 2x PNG to `url`.
    static func renderPNG<V: View>(_ view: V, scheme: ColorScheme, size: CGSize, to url: URL) throws {
        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        let rect = CGRect(origin: .zero, size: size)
        let host = NSHostingView(rootView: view
            .environment(\.colorScheme, scheme)
            .frame(width: size.width, height: size.height))
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
            pixelsWide: Int(size.width * 2),
            pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        rep.size = size
        // Resolve dynamic colours against the requested appearance while drawing.
        appearance?.performAsCurrentDrawingAppearance {
            host.cacheDisplay(in: rect, to: rep)
        }
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try data.write(to: url)
    }
}
