import SwiftUI

/// Initial expansion state for the Providers tab. The defaults are what the
/// app uses; renders and tests can open specific rows.
struct ProvidersLayout {
    var expandedSTT: STTProviderID?
    var expandedLLM: LLMProviderID?
    var openAdvanced: Set<String> = []
}

/// Provider configuration: the active speech and cleanup providers up top,
/// every other provider as a compact row that expands to set up its key.
struct ProvidersSettingsView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var credentials: ProviderCredentials
    @ObservedObject var tester: ProviderKeyTester

    @State private var expandedSTT: STTProviderID?
    @State private var expandedLLM: LLMProviderID?
    @State private var openAdvanced: Set<String>
    @FocusState private var focusedField: String?

    init(
        appState: AppState,
        credentials: ProviderCredentials,
        tester: ProviderKeyTester,
        layout: ProvidersLayout = ProvidersLayout()
    ) {
        self.appState = appState
        self.credentials = credentials
        self.tester = tester
        _expandedSTT = State(initialValue: layout.expandedSTT)
        _expandedLLM = State(initialValue: layout.expandedLLM)
        _openAdvanced = State(initialValue: layout.openAdvanced)
    }

    var body: some View {
        SettingsPage {
            PageHeader(SettingsTab.providers.title, subtitle: SettingsTab.providers.summary)
            speechSection
            otherSpeechSection
            languageSection
            cleanupSection
            otherCleanupSection
        }
        .onChange(of: appState.selectedSTT) { _, provider in
            if expandedSTT == provider { expandedSTT = nil }
            focusMissingKey(of: provider.setupDescriptor)
        }
        .onChange(of: appState.selectedLLM) { _, provider in
            if expandedLLM == provider { expandedLLM = nil }
            focusMissingKey(of: provider.setupDescriptor)
        }
    }

    // MARK: - Speech

    private var speechSection: some View {
        SettingsSection("Speech to text", footer: "Whispur sends each recording to the active provider.") {
            SettingsCard {
                let active = appState.selectedSTT.setupDescriptor
                SettingsRow(icon: "waveform.badge.mic", title: "Speech provider", subtitle: credentials.status(for: active.keys).title) {
                    RowPicker("Speech provider", selection: $appState.selectedSTT) {
                        ForEach(STTProviderID.allCases) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }
                }
                panel(for: active, style: .active, activeNote: nil)

                if appState.selectedSTT.supportsStreaming {
                    CardDivider()
                    SettingsRow(
                        icon: "dot.radiowaves.left.and.right",
                        title: "Stream audio while you talk",
                        subtitle: "Text is ready sooner after you stop. If the stream fails, Whispur sends the recording instead."
                    ) {
                        SettingsSwitch(label: "Stream audio while you talk", isOn: $appState.streamWhileTalking)
                    }
                }
            }
        }
    }

    private var otherSpeechSection: some View {
        SettingsSection("Other speech providers") {
            SettingsCard {
                let others = STTProviderID.allCases.filter { $0 != appState.selectedSTT }
                ForEach(Array(others.enumerated()), id: \.element) { index, provider in
                    if index > 0 { CardDivider(leadingInset: 0) }
                    panel(
                        for: provider.setupDescriptor,
                        style: .row(isExpanded: expandedSTT == provider),
                        activeNote: nil,
                        onToggle: {
                            withSophiieAnimation {
                                expandedSTT = expandedSTT == provider ? nil : provider
                            }
                            if expandedSTT == provider { focusMissingKey(of: provider.setupDescriptor) }
                        },
                        onUse: { appState.selectedSTT = provider }
                    )
                }
            }
        }
    }

    private var languageSection: some View {
        SettingsSection("Language", footer: "Leave it empty to let the provider detect the language. With two or more, providers that accept several get them all, and if a transcript comes back in a script none of your languages use (Arabic for a Spanish clip, say), Whispur transcribes it again in each of your languages and keeps the best.") {
            SettingsCard {
                SpokenLanguagesRow(appState: appState)
            }
        }
    }

    // MARK: - Cleanup

    private var cleanupSection: some View {
        SettingsSection("Cleanup", footer: "Adds punctuation, removes filler, and smooths dictation before paste.") {
            SettingsCard {
                let active = appState.selectedLLM.setupDescriptor
                SettingsRow(icon: "wand.and.stars", title: "Cleanup provider", subtitle: credentials.status(for: active.keys).title) {
                    RowPicker("Cleanup provider", selection: $appState.selectedLLM) {
                        ForEach(LLMProviderID.allCases) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }
                }
                panel(
                    for: active,
                    style: .active,
                    activeNote: credentials.status(for: active.keys).isReady
                        ? nil
                        : "Until a key is saved, Whispur pastes the raw transcript without cleanup."
                )
            }
        }
    }

    private var otherCleanupSection: some View {
        SettingsSection("Other cleanup providers") {
            SettingsCard {
                let others = LLMProviderID.allCases.filter { $0 != appState.selectedLLM }
                ForEach(Array(others.enumerated()), id: \.element) { index, provider in
                    if index > 0 { CardDivider(leadingInset: 0) }
                    panel(
                        for: provider.setupDescriptor,
                        style: .row(isExpanded: expandedLLM == provider),
                        activeNote: nil,
                        onToggle: {
                            withSophiieAnimation {
                                expandedLLM = expandedLLM == provider ? nil : provider
                            }
                            if expandedLLM == provider { focusMissingKey(of: provider.setupDescriptor) }
                        },
                        onUse: { appState.selectedLLM = provider }
                    )
                }
            }
        }
    }

    // MARK: - Building blocks

    private func panel(
        for descriptor: ProviderDescriptor,
        style: ProviderSetupPanel.Style,
        activeNote: String?,
        onToggle: @escaping () -> Void = {},
        onUse: (() -> Void)? = nil
    ) -> some View {
        ProviderSetupPanel(
            descriptor: descriptor,
            style: style,
            activeNote: activeNote,
            credentials: credentials,
            tester: tester,
            focus: $focusedField,
            isAdvancedOpen: Binding(
                get: { openAdvanced.contains(descriptor.id) },
                set: { isOpen in
                    if isOpen { openAdvanced.insert(descriptor.id) } else { openAdvanced.remove(descriptor.id) }
                }
            ),
            onToggle: onToggle,
            onUse: onUse
        )
    }

    /// Moves focus to the first missing key of a provider the user just
    /// picked or expanded, so they can paste straight away.
    private func focusMissingKey(of descriptor: ProviderDescriptor) {
        guard let missing = descriptor.keys.first(where: { !credentials.has($0) }) else { return }
        let fieldID = ProviderSetupPanel.fieldID(descriptor: descriptor, key: missing)
        DispatchQueue.main.async { focusedField = fieldID }
    }
}

/// "Languages I speak": a menu of checkable languages plus a chip per
/// chosen language. Empty means auto-detect.
private struct SpokenLanguagesRow: View {
    @ObservedObject var appState: AppState

    private var selection: STTLanguageSelection { appState.sttLanguageSelection }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow(
                icon: "character.bubble",
                title: "Languages I speak",
                subtitle: SpokenLanguagesRow.footnote(for: appState.selectedSTT, selection: selection)
            ) {
                Menu {
                    Button {
                        appState.sttLanguageSelection = .auto
                    } label: {
                        if selection.isAuto { Label("Auto-detect", systemImage: "checkmark") } else { Text("Auto-detect") }
                    }
                    Divider()
                    ForEach(STTLanguageCatalog.all) { language in
                        Toggle(language.displayName, isOn: binding(for: language.code))
                    }
                } label: {
                    Text(menuTitle)
                }
                .menuStyle(.button)
                .fixedSize()
                .accessibilityLabel("Languages I speak")
            }
            if !selection.isAuto {
                FlowLayout {
                    ForEach(selection.codes, id: \.self) { code in
                        RemovableChip(
                            title: STTLanguageCatalog.displayName(for: code),
                            removeLabel: "Remove \(STTLanguageCatalog.displayName(for: code))"
                        ) {
                            set(code, on: false)
                        }
                    }
                }
                .padding(.leading, SettingsMetrics.textInset)
                .padding(.bottom, 12)
            }
        }
    }

    private var menuTitle: String {
        switch selection.codes.count {
        case 0: "Auto-detect"
        case 1: STTLanguageCatalog.displayName(for: selection.codes[0])
        default: "\(selection.codes.count) languages"
        }
    }

    private func binding(for code: String) -> Binding<Bool> {
        Binding(
            get: { selection.codes.contains(code) },
            set: { set(code, on: $0) }
        )
    }

    private func set(_ code: String, on: Bool) {
        let codes = selection.codes.filter { $0 != code } + (on ? [code] : [])
        appState.sttLanguageSelection = STTLanguageSelection(codes: codes)
    }

    static func footnote(for provider: STTProviderID, selection: STTLanguageSelection) -> String {
        if selection.isAuto {
            switch provider {
            case .deepgram:
                return "Deepgram will use nova-3's multilingual mode."
            case .apple:
                return "Apple has no auto mode, so Whispur falls back to your system language."
            default:
                return "The provider will detect the language on each recording."
            }
        }
        guard selection.isMultilingual else {
            return "Whispur will tell \(provider.displayName) which language to expect."
        }
        switch provider {
        case .openai:
            return OpenAISTT.usesKeywordShape(model: ProviderRegistry.sttModel(for: .openai) ?? "")
                ? "OpenAI gets all of your languages as hints."
                : "This OpenAI model takes one language, so it detects which of yours you're speaking."
        case .deepgram:
            return "Deepgram uses nova-3's multilingual mode with your languages as hints."
        case .metaMuse:
            return "Meta Muse is steered toward your languages."
        case .apple:
            return "Apple listens in one language: your system language if it's on the list, otherwise the first one."
        case .groqWhisper, .elevenlabs, .mistral:
            return "\(provider.displayName) takes one language, so it detects which of yours you're speaking."
        }
    }
}
