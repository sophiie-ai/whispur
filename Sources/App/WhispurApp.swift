import SwiftUI

@main
struct WhispurApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(appState: appState)
        } label: {
            Image(systemName: menuBarIcon)
                .symbolRenderingMode(.hierarchical)
        }
        .menuBarExtraStyle(.window)

        Window("Whispur Settings", id: "settings") {
            SettingsView(appState: appState)
                .frame(minWidth: 860, minHeight: 620)
        }
        .defaultSize(width: 980, height: 680)
        .windowResizability(.contentSize)
    }

    private var menuBarIcon: String {
        switch appState.pipeline.phase {
        case .idle:
            return "waveform"
        case .requestingMicrophonePermission, .starting:
            return "mic.badge.clock"
        case .recording:
            return "record.circle.fill"
        case .normalizingAudio, .transcribing, .cleaningTranscript, .pasting:
            return "ellipsis.circle"
        case .done:
            return "checkmark.circle.fill"
        case .error:
            return "exclamationmark.triangle.fill"
        }
    }
}
