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
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Whispur")
                    .font(.title3.weight(.semibold))
                Text(selectedTab.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tab.rawValue)
                                Text(tab.subtitle)
                                    .font(.caption2)
                                    .foregroundStyle(selectedTab == tab ? Color.primary.opacity(0.72) : Color.secondary)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(selectedTab == tab ? Color.orange.opacity(0.15) : Color.clear)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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
                    .foregroundStyle(.secondary)
            }
            .padding(18)
        }
        .frame(width: 240)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
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
