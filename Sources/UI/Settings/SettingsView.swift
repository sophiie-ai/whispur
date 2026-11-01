import AppKit
import SwiftUI

/// Main settings window: a midnight sidebar of pages on the left, the
/// selected page on the right. The window hides its title bar, so the
/// sidebar runs edge to edge under the native traffic lights.
struct SettingsView: View {
    /// UserDefaults key for the selected page. Writing an empty string asks
    /// the window to open on its landing page.
    static let selectedTabKey = "settings.selectedTab"

    /// Height of the hidden title bar strip that keeps the traffic lights
    /// and window dragging.
    static let titleBarHeight: CGFloat = 32

    /// Permission state for renders, which can't grant real permissions.
    struct PermissionsOverride {
        var microphone: Bool
        var accessibility: Bool
    }

    @ObservedObject var appState: AppState
    @ObservedObject private var historyStore: PipelineHistoryStore
    @StateObject private var credentials: ProviderCredentials
    @StateObject private var tester: ProviderKeyTester
    @AppStorage private var selectedTabRaw: String

    private let providersLayout: ProvidersLayout
    private let permissionsOverride: PermissionsOverride?

    /// - Parameters:
    ///   - secretStore: Where provider keys live. Defaults to the Keychain;
    ///     tests and renders pass an in-memory store.
    ///   - keyTestResults: Seeds key check results (renders only).
    ///   - providersLayout: Initial row expansion on the Providers page.
    ///   - permissionsOverride: Fixed permission state (renders only).
    ///   - defaults: Where the selected page is remembered (renders pass a
    ///     scratch suite).
    @MainActor
    init(
        appState: AppState,
        secretStore: SecretStore? = nil,
        keyTestResults: [String: ProviderKeyTestState] = [:],
        providersLayout: ProvidersLayout = ProvidersLayout(),
        permissionsOverride: PermissionsOverride? = nil,
        defaults: UserDefaults = .standard
    ) {
        _selectedTabRaw = AppStorage(wrappedValue: "", SettingsView.selectedTabKey, store: defaults)
        self.appState = appState
        self.historyStore = appState.historyStore
        self.providersLayout = providersLayout
        self.permissionsOverride = permissionsOverride
        _credentials = StateObject(wrappedValue: ProviderCredentials(store: secretStore ?? appState.keychain))
        _tester = StateObject(wrappedValue: ProviderKeyTester(requestLog: appState.providerRequestLog, results: keyTestResults))
    }

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(
                selection: selectionBinding,
                pendingSetupSteps: setupState.pendingSteps,
                status: sidebarStatus
            )
            page
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(SophiieTheme.Palette.surfaceWarm)
        }
        .background(alignment: .top) {
            WindowDragRegion()
                .frame(height: SettingsView.titleBarHeight)
                .accessibilityHidden(true)
        }
        .ignoresSafeArea(.container, edges: .top)
        .foregroundStyle(SophiieTheme.Palette.ink)
        .tint(SophiieTheme.Palette.accent)
        .onAppear {
            credentials.reload()
            credentials.onChange = { [weak appState] in appState?.objectWillChange.send() }
        }
    }

    // MARK: - State

    private var microphoneGranted: Bool {
        permissionsOverride?.microphone ?? appState.microphoneAccessGranted
    }

    private var accessibilityGranted: Bool {
        permissionsOverride?.accessibility ?? appState.hotkeyManager.isAccessibilityGranted
    }

    private var readiness: SettingsReadiness {
        let speech = appState.selectedSTT.setupDescriptor
        let cleanup = appState.selectedLLM.setupDescriptor
        return SettingsReadiness.derive(
            microphoneGranted: microphoneGranted,
            accessibilityGranted: accessibilityGranted,
            speechProviderName: speech.name,
            speechStatus: credentials.status(for: speech.keys),
            cleanupProviderName: cleanup.name,
            cleanupStatus: credentials.status(for: cleanup.keys)
        )
    }

    private var setupState: SettingsSetupState {
        SettingsSetupState(
            microphoneGranted: microphoneGranted,
            accessibilityGranted: accessibilityGranted,
            speechReady: credentials.status(for: appState.selectedSTT.setupDescriptor.keys).isReady,
            hasDictated: !historyStore.items.isEmpty
        )
    }

    private var sidebarStatus: SidebarStatus {
        let cleanup = appState.selectedLLM.setupDescriptor
        return SidebarStatus.derive(
            dictationEnabled: appState.dictationEnabled,
            readiness: readiness,
            speechProviderName: appState.selectedSTT.setupDescriptor.name,
            cleanupProviderName: cleanup.name,
            cleanupReady: credentials.status(for: cleanup.keys).isReady
        )
    }

    private var selectedTab: SettingsTab {
        SettingsTab(storedValue: selectedTabRaw) ?? setupState.landingTab
    }

    private var selectionBinding: Binding<SettingsTab> {
        Binding(get: { selectedTab }, set: { selectedTabRaw = $0.rawValue })
    }

    private func open(_ tab: SettingsTab) {
        selectedTabRaw = tab.rawValue
    }

    // MARK: - Pages

    @ViewBuilder
    private var page: some View {
        switch selectedTab {
        case .dictation:
            DictationSettingsView(
                appState: appState,
                historyStore: historyStore,
                stats: appState.stats,
                isReady: setupState.isComplete,
                openTab: open
            )
        case .dictionary, .styles:
            LegacyPage(tab: .dictionary) {
                PromptsSettingsView(appState: appState)
            }
        case .getStarted:
            LegacyPage(tab: .getStarted) {
                SetupSettingsView(appState: appState, openTab: open)
            }
        case .providers:
            LegacyPage(tab: .providers) {
                ProvidersSettingsView(appState: appState, credentials: credentials, tester: tester, layout: providersLayout)
            }
        case .preferences:
            LegacyPage(tab: .preferences) {
                GeneralSettingsView(appState: appState)
            }
        case .activity:
            LegacyPage(tab: .activity) {
                RunLogView(appState: appState)
            }
        case .requests:
            LegacyPage(tab: .requests) {
                RequestsSettingsView(appState: appState)
            }
        }
    }
}

/// A page that still uses the pre-redesign layout under the new header.
private struct LegacyPage<Content: View>: View {
    let tab: SettingsTab
    let content: Content

    init(tab: SettingsTab, @ViewBuilder content: () -> Content) {
        self.tab = tab
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(tab.title, subtitle: tab.summary)
                .padding(.horizontal, 24)
                .padding(.top, SettingsView.titleBarHeight + 6)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

/// Lets the hidden title bar strip move the window, so dragging works even
/// where SwiftUI content would otherwise swallow the click.
private struct WindowDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                // Follow the system "double-click a window's title bar" setting.
                switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
                case "Minimize": window?.performMiniaturize(nil)
                case "None": break
                default: window?.performZoom(nil)
                }
            } else {
                window?.performDrag(with: event)
            }
        }
    }
}
