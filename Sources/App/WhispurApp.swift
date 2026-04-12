import SwiftUI

@main
struct WhispurApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(appState: appState)
        } label: {
            MenuBarStatusIcon(phase: appState.pipeline.phase)
                .task {
                    appDelegate.connect(appState: appState)
                }
        }
        .menuBarExtraStyle(.window)

        Window("Whispur Settings", id: "settings") {
            SettingsView(appState: appState)
                .frame(minWidth: 860, minHeight: 620)
        }
        .defaultSize(width: 980, height: 680)
        .windowResizability(.contentSize)

        Window("About Whispur", id: "about") {
            AboutView()
        }
        .defaultSize(width: 360, height: 360)
        .windowResizability(.contentSize)
    }
}

private struct MenuBarStatusIcon: View {
    let phase: PipelinePhase
    @AppStorage("settings.selectedTab") private var selectedTabRaw = SettingsTab.setup.rawValue
    @Environment(\.openWindow) private var openWindow

    @ViewBuilder
    var body: some View {
        Group {
            switch phase {
            case .recording:
                PulsingMenuBarIcon()
            case .normalizingAudio, .transcribing, .cleaningTranscript, .pasting:
                SpinningMenuBarIcon()
            case .idle:
                MenuBarGlyphIcon()
            case .requestingMicrophonePermission, .starting:
                MenuBarGlyphIcon(tint: .secondary)
                    .opacity(0.86)
            case .done:
                MenuBarGlyphIcon(tint: .green)
            case .error:
                MenuBarGlyphIcon(tint: .orange)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .whispurOpenSettings)) { notification in
            if let tab = notification.object as? String {
                selectedTabRaw = tab
            }
            openWindow(id: "settings")
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

private struct MenuBarGlyphIcon: View {
    var tint: Color = .primary

    var body: some View {
        Image("MenuBarGlyph")
            .renderingMode(.template)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: 16, height: 16)
            .foregroundStyle(tint)
            .accessibilityLabel("Whispur")
    }
}

private struct PulsingMenuBarIcon: View {
    @State private var isAnimating = false

    var body: some View {
        MenuBarGlyphIcon(tint: .red)
            .scaleEffect(isAnimating ? 1.04 : 0.92)
            .opacity(isAnimating ? 1 : 0.72)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: isAnimating)
            .onAppear {
                isAnimating = true
            }
    }
}

private struct SpinningMenuBarIcon: View {
    @State private var isAnimating = false

    var body: some View {
        MenuBarGlyphIcon(tint: .blue)
            .rotationEffect(.degrees(isAnimating ? 360 : 0))
            .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: isAnimating)
            .onAppear {
                isAnimating = true
            }
    }
}
