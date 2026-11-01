import AppKit
import SwiftUI

/// The Dictation page: the master switch, recent history, links to
/// personalization, and the two recording shortcuts.
struct DictationSettingsView: View {
    /// Where "Share feedback" goes. The app has no feedback form, so it opens
    /// a new GitHub issue.
    static let feedbackURL = URL(string: "https://github.com/sophiie-ai/whispur/issues/new")!

    /// How many recent dictations the History card lists.
    static let recentCount = 5

    @ObservedObject var appState: AppState
    @ObservedObject var historyStore: PipelineHistoryStore
    @ObservedObject var stats: DictationStats
    @ObservedObject var vocabulary: VocabularyStore
    @ObservedObject var styles: StyleStore
    let isReady: Bool
    let openTab: (SettingsTab) -> Void

    var body: some View {
        SettingsPage {
            PageHeader(
                "Dictation",
                pill: isReady ? "Ready" : "Needs setup",
                pillTone: isReady ? .info : .warning
            ) {
                Button("Share feedback") {
                    NSWorkspace.shared.open(Self.feedbackURL)
                }
                .buttonStyle(.sophiieSecondary)
                .help("Opens a new issue on GitHub")
            }

            SettingsCard(hero: true) {
                SettingsRow(
                    icon: "waveform",
                    title: "Dictation",
                    subtitle: appState.dictationEnabled
                        ? "Talk instead of type, in any app"
                        : "Shortcuts are paused. Turn this on to dictate again."
                ) {
                    SettingsSwitch(label: "Dictation", isOn: dictationEnabledBinding)
                }
            }

            historySection
            personalizationSection
            shortcutsSection
        }
    }

    // MARK: - History

    private var historySection: some View {
        SettingsSection("History") {
            SettingsCard {
                SettingsLinkRow(
                    icon: "clock.arrow.circlepath",
                    title: "History",
                    subtitle: "View your full dictation history",
                    value: Self.dictationCountLabel(stats.totalDictations)
                ) {
                    openTab(.activity)
                }

                let recent = Array(historyStore.items.prefix(Self.recentCount))
                CardDivider(leadingInset: 0)
                if recent.isEmpty {
                    Text("Your dictations will show up here.")
                        .font(.system(size: 13))
                        .foregroundStyle(SophiieTheme.Palette.muted)
                        .padding(.vertical, 10)
                } else {
                    ForEach(Array(recent.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { CardDivider(leadingInset: 0) }
                        HistoryRow(date: Self.shortDate(item.timestamp), text: Self.previewText(item))
                    }
                }
            }
        }
    }

    static func dictationCountLabel(_ count: Int) -> String {
        let number = count.formatted(.number)
        return count == 1 ? "1 dictation" : "\(number) dictations"
    }

    static func shortDate(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated))
    }

    /// One line of the cleaned text (the raw transcript if cleanup produced
    /// nothing), with line breaks folded into spaces.
    static func previewText(_ item: PipelineResult) -> String {
        if item.isFailed { return "Failed: \(item.failure?.error ?? "")" }
        let cleaned = item.cleanedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = cleaned.isEmpty ? item.rawTranscript : cleaned
        return text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: - Personalization

    private var personalizationSection: some View {
        SettingsSection("Personalization") {
            SettingsCard {
                SettingsLinkRow(
                    icon: "book.closed",
                    title: "Dictionary",
                    subtitle: "Teach Whispur the names and terms you use",
                    value: Self.termCountLabel(vocabulary.terms.count)
                ) {
                    openTab(.dictionary)
                }
                CardDivider()
                SettingsLinkRow(
                    icon: "textformat",
                    title: "Styles",
                    subtitle: "Choose a writing style for each app",
                    value: Self.stylesSummary(styles.settings)
                ) {
                    openTab(.styles)
                }
            }
        }
    }

    /// "4 groups", plus how many apps have their own style.
    static func stylesSummary(_ settings: StyleSettings) -> String {
        let count = settings.overrides.count
        let base = "\(AppGroup.allCases.count) groups"
        guard count > 0 else { return base }
        return base + (count == 1 ? ", 1 app" : ", \(count) apps")
    }

    static func termCountLabel(_ count: Int) -> String {
        count == 1 ? "1 term" : "\(count.formatted(.number)) terms"
    }

    // MARK: - Shortcuts

    private var shortcutsSection: some View {
        SettingsSection("Shortcuts") {
            SettingsCard {
                styleRow
                CardDivider()
                if appState.shortcutStyle == .tapOrHold {
                    tapOrHoldRow
                } else {
                    separateRows
                }
            }
        }
    }

    private var styleRow: some View {
        SettingsRow(
            icon: "keyboard",
            title: "Shortcut style",
            subtitle: Self.styleSubtitle(appState.shortcutStyle)
        ) {
            RowPicker("Shortcut style", selection: shortcutStyleBinding) {
                ForEach(DictationShortcutStyle.allCases) { style in
                    Text(style.displayName).tag(style)
                }
            }
        }
    }

    static func styleSubtitle(_ style: DictationShortcutStyle) -> String {
        switch style {
        case .separate: return "One key to hold and talk, another for hands-free"
        case .tapOrHold: return "One key for both: tap to lock, hold to talk"
        }
    }

    /// Quick taps of a bare Fn also reach macOS (Emoji & Symbols, input
    /// source, Dictation) unless the Globe key is set to Do Nothing.
    static let fnTapHint = "Quick Fn taps also trigger macOS. Set \"Press \u{1F310} key to\" to Do Nothing in System Settings > Keyboard, and make sure Dictation doesn't use Fn twice."

    static func needsFnTapHint(_ binding: ShortcutBinding) -> Bool {
        binding.keyCode == nil && binding.modifiers == .function
    }

    private var tapOrHoldRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow(icon: "hand.tap", title: "Tap or hold", subtitle: Self.tapOrHoldSubtitle) {
                ShortcutMenu(
                    title: "Tap or hold shortcut",
                    current: appState.tapOrHoldShortcut,
                    presets: ShortcutBinding.holdPresets,
                    unavailable: nil,
                    onSelect: { appState.setTapOrHoldShortcut($0) }
                )
            }
            if Self.needsFnTapHint(appState.tapOrHoldShortcut) {
                fnTapHintLabel
            }
        }
    }

    static let tapOrHoldSubtitle = "Hold to talk, release to finish. Tap to lock hands-free, tap again to finish."

    private var fnTapHintLabel: some View {
        Label(Self.fnTapHint, systemImage: "info.circle")
            .font(SophiieTheme.Typography.caption)
            .foregroundStyle(SophiieTheme.Palette.muted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, SettingsMetrics.textInset)
            .padding(.bottom, 12)
    }

    @ViewBuilder
    private var separateRows: some View {
        holdRow
        if appState.holdShortcut == nil {
            addShortcutButton(
                title: "Add hold to talk shortcut",
                presets: ShortcutBinding.holdPresets,
                unavailable: appState.toggleShortcut,
                onSelect: { appState.setHoldShortcut($0) }
            )
        }
        CardDivider()
        handsFreeRow
        if appState.toggleShortcut == nil {
            addShortcutButton(
                title: "Add hands-free shortcut",
                presets: ShortcutBinding.togglePresets,
                unavailable: appState.holdShortcut,
                onSelect: { appState.setToggleShortcut($0) }
            )
        }
        if !appState.hasAnyShortcut {
            CardDivider(leadingInset: 0)
            Label(Self.noShortcutHint, systemImage: "exclamationmark.triangle")
                .font(SophiieTheme.Typography.caption)
                .foregroundStyle(SophiieTheme.Palette.warning)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 12)
        }
    }

    /// Shown when both shortcuts are removed.
    static let noShortcutHint = "No shortcut set. Dictation only starts from Start in the menu bar until you add one."

    private func addShortcutButton(
        title: String,
        presets: [ShortcutBinding],
        unavailable: ShortcutBinding?,
        onSelect: @escaping (ShortcutBinding) -> Void
    ) -> some View {
        HStack {
            Spacer()
            AddShortcutMenu(title: title, presets: presets, unavailable: unavailable, onSelect: onSelect)
        }
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var holdRow: some View {
        if let hold = appState.holdShortcut {
            SettingsRow(icon: "hand.raised", title: "Hold to talk", subtitle: "Hold to dictate. Release to finish.") {
                HStack(spacing: 4) {
                    ShortcutMenu(
                        title: "Hold to talk shortcut",
                        current: hold,
                        presets: ShortcutBinding.holdPresets,
                        unavailable: appState.toggleShortcut,
                        onSelect: { appState.setHoldShortcut($0) }
                    )
                    InlineIconButton(systemName: "xmark", label: "Remove hold to talk shortcut") {
                        appState.setHoldShortcut(nil)
                    }
                }
            }
        } else {
            SettingsRow(
                icon: "hand.raised",
                title: "Hold to talk",
                subtitle: "Off. Add a shortcut to dictate while holding a key."
            )
        }
    }

    @ViewBuilder
    private var handsFreeRow: some View {
        if let toggle = appState.toggleShortcut {
            VStack(alignment: .leading, spacing: 0) {
                SettingsRow(icon: "infinity", title: "Hands-free", subtitle: Self.handsFreeSubtitle(toggle)) {
                    HStack(spacing: 4) {
                        ShortcutMenu(
                            title: "Hands-free shortcut",
                            current: toggle,
                            presets: ShortcutBinding.togglePresets,
                            unavailable: appState.holdShortcut,
                            onSelect: { appState.setToggleShortcut($0) }
                        )
                        InlineIconButton(systemName: "xmark", label: "Remove hands-free shortcut") {
                            appState.setToggleShortcut(nil)
                        }
                    }
                }
                if toggle.isDoublePress {
                    fnTapHintLabel
                }
            }
        } else {
            SettingsRow(
                icon: "infinity",
                title: "Hands-free",
                subtitle: "Off. Add a shortcut to dictate without holding a key."
            )
        }
    }

    static func handsFreeSubtitle(_ binding: ShortcutBinding) -> String {
        if binding.isDoublePress {
            return "Press twice to start. Press once to finish."
        }
        return "Press to start. Press again to finish."
    }

    private var shortcutStyleBinding: Binding<DictationShortcutStyle> {
        Binding(
            get: { appState.shortcutStyle },
            set: { appState.setShortcutStyle($0) }
        )
    }

    private var dictationEnabledBinding: Binding<Bool> {
        Binding(
            get: { appState.dictationEnabled },
            set: { appState.setDictationEnabled($0) }
        )
    }
}

// MARK: - Shortcut controls

/// The current shortcut drawn as keycaps; clicking opens the preset list.
/// One shortcut per action: picking a preset replaces the current one.
struct ShortcutMenu: View {
    let title: String
    let current: ShortcutBinding
    let presets: [ShortcutBinding]
    /// The other action's shortcut, which this one can't reuse.
    let unavailable: ShortcutBinding?
    let onSelect: (ShortcutBinding) -> Void

    var body: some View {
        Menu {
            ForEach(presets, id: \.self) { preset in
                Button {
                    onSelect(preset)
                } label: {
                    if preset == current {
                        Label(preset.menuTitle, systemImage: "checkmark")
                    } else {
                        Text(preset.menuTitle)
                    }
                }
                .disabled(preset == unavailable)
            }
        } label: {
            KeycapCombo(keys: current.keycapLabels, join: current.isDoublePress ? .sequence : .chord)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Change shortcut")
        .accessibilityLabel("\(title): \(current.menuTitle)")
        .accessibilityHint("Shows other shortcuts")
    }
}

/// "Add shortcut", shown only while an action has no shortcut.
struct AddShortcutMenu: View {
    /// Accessibility label, e.g. "Add hands-free shortcut".
    let title: String
    let presets: [ShortcutBinding]
    let unavailable: ShortcutBinding?
    let onSelect: (ShortcutBinding) -> Void

    var body: some View {
        Menu {
            ForEach(presets, id: \.self) { preset in
                Button(preset.menuTitle) { onSelect(preset) }
                    .disabled(preset == unavailable)
            }
        } label: {
            Text("Add shortcut")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(SophiieTheme.Palette.interactive)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(title)
    }
}
