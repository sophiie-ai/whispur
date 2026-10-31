import SwiftUI

/// Main settings window with sidebar navigation.
struct SettingsView: View {
    @ObservedObject var appState: AppState
    @AppStorage("settings.selectedTab") private var selectedTabRaw = SettingsTab.setup.rawValue

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            content
        }
        .background(SophiieTheme.Palette.surfaceWarm)
        .foregroundStyle(SophiieTheme.Palette.ink)
        .tint(SophiieTheme.Palette.accent)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Whispur")
                    .font(SophiieTheme.Typography.title)
                    .tracking(SophiieTheme.Typography.titleTracking)
                    .foregroundStyle(SophiieTheme.Palette.ink)
                Text(selectedTab.subtitle)
                    .font(.caption)
                    .foregroundStyle(SophiieTheme.Palette.muted)
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)

            VStack(spacing: 4) {
                ForEach(SettingsTab.allCases) { tab in
                    Button {
                        selectedTab = tab
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: tab.icon)
                                .frame(width: 16)
                                .foregroundStyle(selectedTab == tab ? SophiieTheme.Palette.ink : SophiieTheme.Palette.muted)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tab.rawValue)
                                    .fontWeight(selectedTab == tab ? .semibold : .regular)
                                    .foregroundStyle(SophiieTheme.Palette.ink)
                                Text(tab.subtitle)
                                    .font(.caption2)
                                    .foregroundStyle(selectedTab == tab ? SophiieTheme.Palette.inkSecondary : SophiieTheme.Palette.muted)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: SophiieTheme.Radius.card, style: .continuous)
                                .fill(selectedTab == tab ? SophiieTheme.Palette.surfaceSelected : Color.clear)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: SophiieTheme.Radius.card, style: .continuous))
                        .sophiieAnimation(value: selectedTab)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(tab.rawValue)
                    .accessibilityHint(tab.subtitle)
                    .accessibilityAddTraits(selectedTab == tab ? [.isButton, .isSelected] : .isButton)
                }
            }
            .padding(.horizontal, 10)

            Spacer()

            VStack(alignment: .leading, spacing: 8) {
                PreferenceBadge(
                    title: appState.isReadyForDailyUse ? "Ready to dictate" : "Setup incomplete",
                    tone: appState.isReadyForDailyUse ? .good : .warning
                )

                Text(appState.shortcutSummary)
                    .font(.caption)
                    .foregroundStyle(SophiieTheme.Palette.muted)
            }
            .padding(18)
        }
        .frame(width: 240)
        .background(SophiieTheme.Palette.surfaceStage)
    }

    @ViewBuilder
    private var content: some View {
        switch selectedTab {
        case .setup:
            SetupSettingsView(appState: appState, openTab: { selectedTab = $0 })
        case .general:
            GeneralSettingsView(appState: appState)
        case .providers:
            ProvidersSettingsView(appState: appState)
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
