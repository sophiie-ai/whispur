import AppKit
import SwiftUI

/// The Styles page: how cleanup reads per app. A default for every other
/// app, a style per app group, per-app overrides, and the custom prompt.
struct StylesSettingsView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var styles: StyleStore
    @ObservedObject var historyStore: PipelineHistoryStore
    @State private var showsDefaultPrompt = false

    /// Styles previewed in the cards across the top.
    private static let previewed: [WritingStyle] = [.casual, .formal, .verbatim, .codeAware]

    var body: some View {
        SettingsPage {
            PageHeader(SettingsTab.styles.title, subtitle: SettingsTab.styles.summary) {
                Button("Reset") { styles.reset() }
                    .buttonStyle(.sophiieSecondary)
                    .disabled(styles.settings == .initial)
                    .help("Back to Default for every group and app, with no per-app styles")
            }

            if !appState.cleanupEnabled {
                cleanupOffNotice
            }

            HStack(spacing: 10) {
                ForEach(Self.previewed) { style in
                    StyleCard(style: style)
                }
            }

            SettingsSection("Default") {
                SettingsCard(hero: true) {
                    SettingsRow(icon: "globe", title: "Every other app", subtitle: "Used when an app has no style of its own") {
                        StylePicker(label: "Default style", selection: Binding(
                            get: { styles.settings.fallback },
                            set: { styles.setFallback($0) }
                        ))
                    }
                }
            }

            SettingsSection("App groups", footer: "Every group starts on Default. Pick a style to change how cleanup reads in those apps.") {
                SettingsCard {
                    ForEach(Array(AppGroup.allCases.enumerated()), id: \.element) { index, group in
                        if index > 0 { CardDivider() }
                        SettingsRow(icon: group.icon, title: group.title, subtitle: group.appNames.joined(separator: ", ")) {
                            StylePicker(label: "\(group.title) style", selection: Binding(
                                get: { styles.settings.style(for: group) },
                                set: { styles.setStyle($0, for: group) }
                            ))
                        }
                    }
                }
            }

            perAppSection
            customSection
        }
    }

    static let cleanupOffTitle = "Styles need cleanup"
    static let cleanupOffDetail = "Clean up with AI is off, so Whispur pastes what the speech engine heard and these styles have no effect."

    private var cleanupOffNotice: some View {
        SettingsCard(hero: true) {
            SettingsRow(
                icon: "info.circle",
                title: Self.cleanupOffTitle,
                subtitle: Self.cleanupOffDetail,
                iconTint: SophiieTheme.Palette.warning
            ) {
                Button("Turn On Cleanup") { appState.cleanupEnabled = true }
                    .buttonStyle(.sophiieSecondary)
                    .help("Switches on Clean up with AI (also on the Providers page)")
            }
        }
    }

    // MARK: - Per app

    private var perAppSection: some View {
        SettingsSection("Per app", footer: "An app's own style wins over its group and the default.") {
            SettingsCard {
                ForEach(styles.settings.overrides) { override in
                    SettingsRow(icon: nil, title: override.name, subtitle: detail(for: override.bundleID)) {
                        HStack(spacing: 6) {
                            StylePicker(label: "\(override.name) style", selection: Binding(
                                get: { override.style },
                                set: { styles.setOverride(bundleID: override.bundleID, name: override.name, style: $0) }
                            ))
                            InlineIconButton(systemName: "xmark", label: "Remove \(override.name) style") {
                                styles.removeOverride(bundleID: override.bundleID)
                            }
                        }
                    }
                    .modifier(AppIconLeading(bundleID: override.bundleID))
                    CardDivider()
                }
                addAppRow
            }
        }
    }

    private func detail(for bundleID: String) -> String {
        if let group = AppGroup.group(for: bundleID) {
            return "Instead of the \(group.title) group"
        }
        return "Instead of the default"
    }

    private var addAppRow: some View {
        let candidates = AppCandidates.list(
            recentBundleIDs: historyStore.items.compactMap(\.appBundleID),
            excluding: Set(styles.settings.overrides.map(\.bundleID))
        )
        return HStack(spacing: SettingsMetrics.iconGap) {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(SophiieTheme.Palette.interactive)
                .frame(width: SettingsMetrics.iconTile)
                .accessibilityHidden(true)
            Menu {
                if candidates.recent.isEmpty && candidates.running.isEmpty {
                    Text("Open the app you want, then come back")
                }
                if !candidates.recent.isEmpty {
                    Section("Recently dictated in") {
                        ForEach(candidates.recent) { app in
                            Button(app.name) { add(app) }
                        }
                    }
                }
                if !candidates.running.isEmpty {
                    Section("Running now") {
                        ForEach(candidates.running) { app in
                            Button(app.name) { add(app) }
                        }
                    }
                }
            } label: {
                Text("Add an app")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(SophiieTheme.Palette.interactive)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            Spacer()
        }
        .padding(.vertical, SettingsMetrics.rowPadding)
    }

    private func add(_ app: AppCandidates.App) {
        let current = styles.settings.resolve(bundleID: app.bundleID).style
        styles.setOverride(bundleID: app.bundleID, name: app.name, style: current)
    }

    // MARK: - Custom

    private var customSection: some View {
        SettingsSection(
            "Custom style",
            footer: "Pick Custom for an app or group to clean up with this prompt instead. While it is empty, Custom works like Default."
        ) {
            SettingsCard {
                CardContent {
                    VStack(alignment: .leading, spacing: 12) {
                        TextEditor(text: $appState.customSystemPrompt)
                            .font(.system(.body, design: .monospaced))
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 140)
                            .padding(8)
                            .background(SophiieTheme.Palette.surfaceSubtle, in: RoundedRectangle(cornerRadius: SophiieTheme.Radius.control, style: .continuous))
                            .accessibilityLabel("Custom cleanup prompt")
                        HStack {
                            PreferenceBadge(
                                title: appState.customSystemPrompt.isEmpty ? "Empty" : "Custom prompt set",
                                tone: appState.customSystemPrompt.isEmpty ? .neutral : .good
                            )
                            Spacer()
                            if !appState.customSystemPrompt.isEmpty {
                                Button("Clear") { appState.customSystemPrompt = "" }
                                    .buttonStyle(.sophiieSecondary)
                                    .controlSize(.small)
                            }
                        }
                    }
                }
                CardDivider(leadingInset: 0)
                DefaultPromptDisclosure(isExpanded: $showsDefaultPrompt)
            }
        }
    }
}

/// Native pop-up of the six styles.
private struct StylePicker: View {
    let label: String
    @Binding var selection: WritingStyle

    var body: some View {
        RowPicker(label, selection: $selection) {
            ForEach(WritingStyle.allCases) { style in
                Text(style.title).tag(style)
            }
        }
    }
}

/// Preview card: style name and a sample of its output.
private struct StyleCard: View {
    let style: WritingStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: style.icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SophiieTheme.Palette.interactive)
                    .accessibilityHidden(true)
                Text(style.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(SophiieTheme.Palette.ink)
                    .lineLimit(1)
            }
            Text(style.sample)
                .font(.system(size: 11.5))
                .foregroundStyle(SophiieTheme.Palette.inkSecondary)
                .lineLimit(2, reservesSpace: true)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SophiieTheme.Palette.surface, in: RoundedRectangle(cornerRadius: SophiieTheme.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: SophiieTheme.Radius.card, style: .continuous)
                .strokeBorder(SophiieTheme.Palette.border, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }
}

/// Puts the app's own icon in the icon-tile slot of a row.
private struct AppIconLeading: ViewModifier {
    let bundleID: String

    func body(content: Content) -> some View {
        HStack(spacing: SettingsMetrics.iconGap) {
            AppIcon(bundleID: bundleID)
            content
        }
    }
}

private struct AppIcon: View {
    let bundleID: String

    var body: some View {
        Group {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                IconTile(systemName: "app")
            }
        }
        .frame(width: SettingsMetrics.iconTile, height: SettingsMetrics.iconTile)
        .accessibilityHidden(true)
    }
}

/// Apps the user can give their own style.
enum AppCandidates {
    struct App: Identifiable, Equatable {
        let bundleID: String
        let name: String
        var id: String { bundleID }
    }

    /// Apps dictated in recently (newest first) and regular apps running
    /// now, without duplicates, Whispur itself, or apps already overridden.
    @MainActor
    static func list(
        recentBundleIDs: [String],
        excluding: Set<String>,
        running: [NSRunningApplication] = NSWorkspace.shared.runningApplications,
        ownBundleID: String? = Bundle.main.bundleIdentifier
    ) -> (recent: [App], running: [App]) {
        var seen = excluding
        if let ownBundleID { seen.insert(ownBundleID) }

        var recent: [App] = []
        for bundleID in recentBundleIDs where !seen.contains(bundleID) {
            seen.insert(bundleID)
            recent.append(App(bundleID: bundleID, name: displayName(for: bundleID)))
        }

        var runningApps: [App] = []
        for app in running where app.activationPolicy == .regular {
            guard let bundleID = app.bundleIdentifier, !seen.contains(bundleID) else { continue }
            seen.insert(bundleID)
            runningApps.append(App(bundleID: bundleID, name: app.localizedName ?? displayName(for: bundleID)))
        }
        runningApps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return (recent, runningApps)
    }

    static func displayName(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
    }
}
