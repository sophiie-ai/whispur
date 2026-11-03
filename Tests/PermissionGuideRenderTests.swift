import AppKit
import SwiftUI
import XCTest
@testable import Whispur

/// Renders the permission guide and the onboarding permission steps to PNG
/// for visual review. Skipped unless `WHISPUR_RENDER_SETTINGS` is set (pass
/// `TEST_RUNNER_WHISPUR_RENDER_SETTINGS=1` to xcodebuild). Output goes to
/// `WHISPUR_RENDER_DIR`, default /tmp/whispur-permission-guide.
@MainActor
final class PermissionGuideRenderTests: XCTestCase {
    func testRenderPermissionGuide() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["WHISPUR_RENDER_SETTINGS"] != nil, "Set WHISPUR_RENDER_SETTINGS to render the permission guide")
        let dir = URL(fileURLWithPath: env["WHISPUR_RENDER_DIR"] ?? "/tmp/whispur-permission-guide")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("whispur-guide-render-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let suite = "ai.sophiie.whispur.render.guide"
        let vocabularyDefaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { vocabularyDefaults.removePersistentDomain(forName: suite) }
        let appState = try SettingsRenderTests.makeAppState(in: scratch, vocabularyDefaults: vocabularyDefaults)
        // Onboarding reads whether the speech provider has keys. Apple speech
        // needs none, so the render never touches the real keychain (which
        // would block on a keychain prompt). Put the real choice back after.
        let sttKey = "selectedSTT"
        let savedSTT = UserDefaults.standard.object(forKey: sttKey)
        defer {
            if let savedSTT { UserDefaults.standard.set(savedSTT, forKey: sttKey) } else { UserDefaults.standard.removeObject(forKey: sttKey) }
        }
        appState.selectedSTT = .apple
        // The language step preselects "Languages I speak"; put that back too.
        let languagesKey = AppState.spokenLanguagesKey
        let savedLanguages = UserDefaults.standard.object(forKey: languagesKey)
        defer {
            if let savedLanguages { UserDefaults.standard.set(savedLanguages, forKey: languagesKey) } else { UserDefaults.standard.removeObject(forKey: languagesKey) }
        }
        let savedDownload = appState.parakeetModel.downloadState
        defer { appState.parakeetModel.setDownloadStateForRendering(savedDownload) }

        let icon = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        icon.size = CGSize(width: 32, height: 32)

        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .dark ? "dark" : "light"
            for permission in GuidedPermission.allCases {
                let guide = PermissionGuideContent(
                    permission: permission,
                    appName: "Whispur",
                    tile: permission.isDraggable ? AnyView(PermissionGuideTile(icon: icon, appName: "Whispur")) : nil,
                    onClose: {}
                )
                .padding(32)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(SophiieTheme.Palette.surfaceWarm)
                let size = CGSize(width: PermissionGuideContent.width + 64, height: PermissionGuideContent.height(for: permission) + 64)
                try render(guide, scheme: scheme, size: size, to: dir.appendingPathComponent("guide-\(permission.rawValue)-\(suffix).png"))
            }

            let onboardingSize = CGSize(width: OnboardingWindow.size.width, height: OnboardingWindow.size.height)
            for step in OnboardingStep.allCases {
                appState.permissionGuide.setActivePermissionForRendering(nil)
                try render(OnboardingWindow(appState: appState, initialStep: step) {}, scheme: scheme, size: onboardingSize,
                           to: dir.appendingPathComponent("onboarding-\(step.title.lowercased().replacingOccurrences(of: " ", with: "-"))-\(suffix).png"))
            }
            // The accessibility step while the guide is open beside System Settings.
            appState.permissionGuide.setActivePermissionForRendering(.accessibility)
            try render(OnboardingWindow(appState: appState, initialStep: .accessibility) {}, scheme: scheme, size: onboardingSize,
                       to: dir.appendingPathComponent("onboarding-accessibility-waiting-\(suffix).png"))
            appState.permissionGuide.setActivePermissionForRendering(nil)

            // Accessibility granted but not yet honoured, then needing a
            // restart; and the ready screen once everything works.
            let savedMicrophone = appState.microphoneAccessGranted
            let savedAccessibility = appState.hotkeyManager.accessibilityStatus
            appState.setMicrophoneAccessForRendering(true)
            let states: [(AccessibilityStatus, OnboardingStep, String)] = [
                (.finishing, .accessibility, "accessibility-finishing"),
                (.needsRestart, .accessibility, "accessibility-restart"),
                (.needsRestart, .tryIt, "try-it-restart"),
                (.needsRestart, .ready, "ready-restart"),
                (.on, .ready, "ready-all-set"),
            ]
            for (status, step, name) in states {
                appState.hotkeyManager.setAccessibilityForRendering(status)
                try render(OnboardingWindow(appState: appState, initialStep: step) {}, scheme: scheme, size: onboardingSize,
                           to: dir.appendingPathComponent("onboarding-\(name)-\(suffix).png"))
            }
            appState.hotkeyManager.setAccessibilityForRendering(savedAccessibility)

            // The welcome story at a few moments, and its Reduce Motion form.
            let storyMoments: [(TimeInterval, String)] = [
                (WelcomeStoryTimeline.lead + 0.6, "listening"),
                (WelcomeStoryTimeline.lead + 1.8, "voice-done"),
                (WelcomeStoryTimeline.lead + 4.0, "typing"),
                (WelcomeStoryTimeline.end, "end"),
            ]
            for (time, name) in storyMoments {
                try render(OnboardingWindow(appState: appState, initialStep: .welcome, storyTime: time) {}, scheme: scheme, size: onboardingSize,
                           to: dir.appendingPathComponent("onboarding-welcome-story-\(name)-\(suffix).png"))
            }
            try render(OnboardingWindow(appState: appState, initialStep: .welcome) {}.environment(\.onboardingRendersReducedMotion, true),
                       scheme: scheme, size: onboardingSize,
                       to: dir.appendingPathComponent("onboarding-welcome-story-reduce-motion-\(suffix).png"))

            // The Parakeet download framing: the language question, then the
            // pill on later screens at 40% and once ready, and on failure.
            appState.sttLanguageSelection = .single(code: "en-US")
            appState.parakeetModel.setDownloadStateForRendering(.downloading(fraction: 0.05, isPreparing: false))
            try render(OnboardingWindow(appState: appState, initialStep: .languages, usesParakeetDownload: true) {}, scheme: scheme, size: onboardingSize,
                       to: dir.appendingPathComponent("onboarding-languages-download-\(suffix).png"))
            appState.sttLanguageSelection = STTLanguageSelection(codes: ["en-US", "es-MX", "ja-JP"])
            try render(OnboardingWindow(appState: appState, initialStep: .languages, usesParakeetDownload: false) {}, scheme: scheme, size: onboardingSize,
                       to: dir.appendingPathComponent("onboarding-languages-no-download-\(suffix).png"))
            appState.sttLanguageSelection = .single(code: "en-US")
            let pillStates: [(ParakeetModelManager.DownloadState, OnboardingStep, String)] = [
                (.downloading(fraction: 0.4, isPreparing: false), .shortcuts, "shortcuts-pill-40"),
                (.downloading(fraction: 0.4, isPreparing: false), .tryIt, "try-it-pill-40"),
                (.installed(bytesOnDisk: 632_000_000), .microphone, "microphone-pill-ready"),
                (.failed("The network connection was lost."), .accessibility, "accessibility-pill-failed"),
            ]
            for (state, step, name) in pillStates {
                appState.parakeetModel.setDownloadStateForRendering(state)
                try render(OnboardingWindow(appState: appState, initialStep: step, usesParakeetDownload: true) {}, scheme: scheme, size: onboardingSize,
                           to: dir.appendingPathComponent("onboarding-\(name)-\(suffix).png"))
            }
            appState.parakeetModel.setDownloadStateForRendering(savedDownload)
            appState.setMicrophoneAccessForRendering(savedMicrophone)
        }
    }

    private func render<V: View>(_ view: V, scheme: ColorScheme, size: CGSize, to url: URL) throws {
        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        let rect = CGRect(origin: .zero, size: size)
        let host = NSHostingView(rootView: view
            .environment(\.colorScheme, scheme)
            .environment(\.onboardingStillFrames, true)
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
        appearance?.performAsCurrentDrawingAppearance {
            host.cacheDisplay(in: rect, to: rep)
        }
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try data.write(to: url)
    }
}
