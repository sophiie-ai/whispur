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

            let onboardingSize = CGSize(width: 760, height: 640)
            for step in [OnboardingStep.microphone, .accessibility] {
                appState.permissionGuide.setActivePermissionForRendering(nil)
                try render(OnboardingWindow(appState: appState, initialStep: step) {}, scheme: scheme, size: onboardingSize,
                           to: dir.appendingPathComponent("onboarding-\(step.title.lowercased())-\(suffix).png"))
            }
            // The accessibility step while the guide is open beside System Settings.
            appState.permissionGuide.setActivePermissionForRendering(.accessibility)
            try render(OnboardingWindow(appState: appState, initialStep: .accessibility) {}, scheme: scheme, size: onboardingSize,
                       to: dir.appendingPathComponent("onboarding-accessibility-waiting-\(suffix).png"))
            appState.permissionGuide.setActivePermissionForRendering(nil)
        }
    }

    private func render<V: View>(_ view: V, scheme: ColorScheme, size: CGSize, to url: URL) throws {
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
        appearance?.performAsCurrentDrawingAppearance {
            host.cacheDisplay(in: rect, to: rep)
        }
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try data.write(to: url)
    }
}
