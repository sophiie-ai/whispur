import AppKit
import SwiftUI

/// Main settings window: an app header and tab list on the left, a titled
/// detail pane on the right. The window hides its title bar, so the brand
/// canvas runs edge to edge under the native traffic lights.
struct SettingsView: View {
    @ObservedObject var appState: AppState
    @StateObject private var credentials: ProviderCredentials
    @StateObject private var tester: ProviderKeyTester
    @AppStorage("settings.selectedTab") private var selectedTabRaw = SettingsTab.setup.rawValue

    private let providersLayout: ProvidersLayout

    /// - Parameters:
    ///   - secretStore: Where provider keys live. Defaults to the Keychain;
    ///     tests and renders pass an in-memory store.
    ///   - keyTestResults: Seeds key check results (renders only).
    ///   - providersLayout: Initial row expansion on the Providers tab.
    @MainActor
    init(
        appState: AppState,
        secretStore: SecretStore? = nil,
        keyTestResults: [String: ProviderKeyTestState] = [:],
        providersLayout: ProvidersLayout = ProvidersLayout()
    ) {
        self.appState = appState
        self.providersLayout = providersLayout
        _credentials = StateObject(wrappedValue: ProviderCredentials(store: secretStore ?? appState.keychain))
        _tester = StateObject(wrappedValue: ProviderKeyTester(requestLog: appState.providerRequestLog, results: keyTestResults))
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle()
                .fill(SophiieTheme.Palette.border)
                .frame(width: 1)
                .accessibilityHidden(true)
            detail
        }
        .background(SophiieTheme.Palette.surfaceWarm)
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

    /// Height of the hidden title bar strip that keeps the traffic lights
    /// and window dragging.
    static let titleBarHeight: CGFloat = 32

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            appHeader
                .padding(.horizontal, 16)
                .padding(.top, SettingsView.titleBarHeight + 12)
                .padding(.bottom, 18)

            VStack(spacing: 2) {
                ForEach(SettingsTab.allCases) { tab in
                    tabButton(tab)
                }
            }
            .padding(.horizontal, 10)

            Spacer(minLength: 12)

            Label(appState.shortcutSummary, systemImage: "keyboard")
                .font(SophiieTheme.Typography.caption)
                .foregroundStyle(SophiieTheme.Palette.muted)
                .padding(18)
        }
        .frame(width: 248)
        .frame(maxHeight: .infinity)
        .background(SophiieTheme.Palette.surfaceStage)
    }

    private var appHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 44, height: 44)
                    .shadow(color: SophiieTheme.Shadow.tint.opacity(0.18), radius: 6, y: 3)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Whispur")
                        .font(SophiieTheme.Typography.title)
                        .tracking(SophiieTheme.Typography.titleTracking)
                        .foregroundStyle(SophiieTheme.Palette.ink)
                    Text(versionLabel)
                        .font(SophiieTheme.Typography.caption)
                        .foregroundStyle(SophiieTheme.Palette.muted)
                }
            }
            .accessibilityElement(children: .combine)

            statusLine
        }
    }

    private var readiness: SettingsReadiness {
        let speech = appState.selectedSTT.setupDescriptor
        let cleanup = appState.selectedLLM.setupDescriptor
        return SettingsReadiness.derive(
            microphoneGranted: appState.microphoneAccessGranted,
            accessibilityGranted: appState.hotkeyManager.isAccessibilityGranted,
            speechProviderName: speech.name,
            speechStatus: credentials.status(for: speech.keys),
            cleanupProviderName: cleanup.name,
            cleanupStatus: credentials.status(for: cleanup.keys)
        )
    }

    @ViewBuilder
    private var statusLine: some View {
        let readiness = readiness
        let isReady = readiness.tone == .ready
        let content = HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(isReady ? SophiieTheme.Palette.success : SophiieTheme.Palette.warning)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(readiness.headline)
                    .font(SophiieTheme.Typography.captionStrong)
                    .foregroundStyle(SophiieTheme.Palette.ink)
                Text(readiness.detail)
                    .font(SophiieTheme.Typography.caption)
                    .foregroundStyle(SophiieTheme.Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if !isReady {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(SophiieTheme.Palette.muted)
                    .accessibilityHidden(true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SophiieTheme.Palette.surface, in: RoundedRectangle(cornerRadius: SophiieTheme.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: SophiieTheme.Radius.card, style: .continuous)
                .strokeBorder(SophiieTheme.Palette.border, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: SophiieTheme.Radius.card, style: .continuous))

        if isReady {
            content
                .accessibilityElement(children: .combine)
        } else {
            Button {
                selectedTab = .setup
            } label: {
                content
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(readiness.headline). \(readiness.detail)")
            .accessibilityHint("Opens Setup")
        }
    }

    private func tabButton(_ tab: SettingsTab) -> some View {
        let isSelected = selectedTab == tab
        return Button {
            selectedTab = tab
        } label: {
            HStack(spacing: 10) {
                Image(systemName: tab.icon)
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? SophiieTheme.Palette.ink : SophiieTheme.Palette.muted)
                Text(tab.rawValue)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(SophiieTheme.Palette.ink)
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: SophiieTheme.Radius.control, style: .continuous)
                    .fill(isSelected ? SophiieTheme.Palette.surfaceSelected : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: SophiieTheme.Radius.control, style: .continuous))
            .sophiieAnimation(value: selectedTab)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.rawValue)
        .accessibilityHint(tab.summary)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var versionLabel: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return version.map { "Version \($0)" } ?? "Version unknown"
    }

    // MARK: - Detail

    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(selectedTab.rawValue)
                    .font(SophiieTheme.Typography.pageTitle)
                    .tracking(SophiieTheme.Typography.titleTracking)
                    .foregroundStyle(SophiieTheme.Palette.ink)
                    .accessibilityAddTraits(.isHeader)
                Text(selectedTab.summary)
                    .font(.subheadline)
                    .foregroundStyle(SophiieTheme.Palette.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, SettingsView.titleBarHeight + 8)
            .padding(.bottom, 2)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch selectedTab {
        case .setup:
            SetupSettingsView(appState: appState, openTab: { selectedTab = $0 })
        case .general:
            GeneralSettingsView(appState: appState)
        case .providers:
            ProvidersSettingsView(appState: appState, credentials: credentials, tester: tester, layout: providersLayout)
        case .prompts:
            PromptsSettingsView(appState: appState)
        case .activity:
            RunLogView(appState: appState)
        case .requests:
            RequestsSettingsView(appState: appState)
        }
    }

    private var selectedTab: SettingsTab {
        get { SettingsTab(rawValue: selectedTabRaw) ?? .setup }
        nonmutating set { selectedTabRaw = newValue.rawValue }
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
