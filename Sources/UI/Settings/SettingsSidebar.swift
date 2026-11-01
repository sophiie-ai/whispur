import AppKit
import SwiftUI

/// What the status card at the foot of the sidebar says.
struct SidebarStatus: Equatable {
    enum Tone: Equatable {
        case ready
        case attention
        case off
    }

    let tone: Tone
    let headline: String
    let detail: String
    /// The page the card opens when clicked, or nil when there is nothing
    /// to fix.
    let target: SettingsTab?

    static func derive(
        dictationEnabled: Bool,
        readiness: SettingsReadiness,
        speechProviderName: String,
        cleanupProviderName: String,
        cleanupReady: Bool
    ) -> SidebarStatus {
        guard readiness.tone == .ready else {
            return SidebarStatus(tone: .attention, headline: "Setup incomplete", detail: readiness.detail, target: .getStarted)
        }
        guard dictationEnabled else {
            return SidebarStatus(tone: .off, headline: "Dictation is off", detail: "Shortcuts are paused.", target: .dictation)
        }
        let cleanup = cleanupReady ? "\(cleanupProviderName) cleanup" : "Cleanup off"
        return SidebarStatus(tone: .ready, headline: "Ready to dictate", detail: "\(speechProviderName) \u{00B7} \(cleanup)", target: nil)
    }
}

/// The always-midnight sidebar: app header, page list, status card.
struct SettingsSidebar: View {
    @Binding var selection: SettingsTab
    let pendingSetupSteps: Int
    let status: SidebarStatus

    private typealias OnDark = SophiieTheme.Palette.OnDark

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            appHeader
                .padding(.horizontal, 16)
                .padding(.top, SettingsView.titleBarHeight + 12)
                .padding(.bottom, 14)

            VStack(alignment: .leading, spacing: 2) {
                ForEach(SettingsTab.Group.allCases, id: \.self) { group in
                    if let title = group.title {
                        SidebarGroupLabel(title: title)
                    }
                    ForEach(SettingsTab.tabs(in: group)) { tab in
                        item(tab)
                    }
                }
            }
            .padding(.horizontal, 10)

            Spacer(minLength: 12)

            statusCard
                .padding(14)
        }
        .frame(width: SettingsMetrics.sidebarWidth)
        .frame(maxHeight: .infinity)
        .background(SophiieTheme.Palette.midnight)
        .overlay(alignment: .trailing) {
            // Keeps the edge visible against the dark-mode canvas.
            Rectangle().fill(OnDark.hairline).frame(width: 1).accessibilityHidden(true)
        }
        .environment(\.colorScheme, .dark)
    }

    private func item(_ tab: SettingsTab) -> some View {
        let isSelected = selection == tab
        let badge = tab == .getStarted && pendingSetupSteps > 0 ? "\(pendingSetupSteps)" : nil
        return Button {
            selection = tab
        } label: {
            SidebarItem(title: tab.title, icon: tab.icon, badge: badge, isSelected: isSelected)
                .sophiieAnimation(value: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(badge.map { "\(tab.title), \($0) steps left" } ?? tab.title)
        .accessibilityHint(tab.summary)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var appHeader: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 34, height: 34)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Whispur")
                    .font(.system(size: 15, weight: .semibold))
                    .tracking(SophiieTheme.Typography.titleTracking)
                    .foregroundStyle(OnDark.ink)
                Text(Self.versionLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(OnDark.muted)
            }
        }
        .accessibilityElement(children: .combine)
    }

    static var versionLabel: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return version.map { "Version \($0)" } ?? "Version unknown"
    }

    @ViewBuilder
    private var statusCard: some View {
        let shape = RoundedRectangle(cornerRadius: SophiieTheme.Radius.card, style: .continuous)
        let content = HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(dotColor)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(status.headline)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(OnDark.ink)
                Text(status.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(OnDark.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if status.target != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(OnDark.muted)
                    .accessibilityHidden(true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OnDark.raised, in: shape)
        .overlay(shape.strokeBorder(OnDark.hairline, lineWidth: 1))
        .contentShape(shape)

        if let target = status.target {
            Button { selection = target } label: { content }
                .buttonStyle(.plain)
                .accessibilityLabel("\(status.headline). \(status.detail)")
                .accessibilityHint("Opens \(target.title)")
        } else {
            content.accessibilityElement(children: .combine)
        }
    }

    private var dotColor: Color {
        switch status.tone {
        case .ready: return OnDark.success
        case .attention: return OnDark.warning
        case .off: return OnDark.muted
        }
    }
}
