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
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                speechCard
                languagesCard
                cleanupCard
            }
            .padding(24)
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

    private var speechCard: some View {
        PreferenceCard(
            "Speech to Text",
            detail: "Whispur sends each recording to the active provider.",
            icon: "waveform.badge.mic"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                activePicker(title: "Speech provider") {
                    Picker("Speech provider", selection: $appState.selectedSTT) {
                        ForEach(STTProviderID.allCases) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }
                }

                panel(for: appState.selectedSTT.setupDescriptor, style: .active, activeNote: nil)

                if appState.selectedSTT.supportsStreaming {
                    StreamingToggle(isOn: $appState.streamWhileTalking)
                }

                otherProvidersLabel

                VStack(spacing: 8) {
                    ForEach(STTProviderID.allCases.filter { $0 != appState.selectedSTT }) { provider in
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
    }

    private var languagesCard: some View {
        PreferenceCard(
            "Preferred Language",
            detail: "Pick the language you speak. Whispur sends this as a hint to the selected speech provider. Auto-detect asks the provider to identify the language itself, which works best when you switch between languages.",
            icon: "character.bubble"
        ) {
            STTLanguagePicker(appState: appState)
        }
    }

    // MARK: - Cleanup

    private var cleanupCard: some View {
        PreferenceCard(
            "Cleanup Model",
            detail: "Adds punctuation, removes filler, and smooths dictation before paste.",
            icon: "wand.and.stars"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                activePicker(title: "Cleanup provider") {
                    Picker("Cleanup provider", selection: $appState.selectedLLM) {
                        ForEach(LLMProviderID.allCases) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }
                }

                let active = appState.selectedLLM.setupDescriptor
                panel(
                    for: active,
                    style: .active,
                    activeNote: credentials.status(for: active.keys).isReady
                        ? nil
                        : "Until a key is saved, Whispur pastes the raw transcript without cleanup."
                )

                otherProvidersLabel

                VStack(spacing: 8) {
                    ForEach(LLMProviderID.allCases.filter { $0 != appState.selectedLLM }) { provider in
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
    }

    // MARK: - Building blocks

    private func activePicker<P: View>(title: String, @ViewBuilder picker: () -> P) -> some View {
        HStack {
            Text(title)
                .font(SophiieTheme.Typography.label)
                .foregroundStyle(SophiieTheme.Palette.ink)
                .accessibilityHidden(true)
            Spacer()
            picker()
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 240)
        }
    }

    private var otherProvidersLabel: some View {
        Text("OTHER PROVIDERS")
            .font(SophiieTheme.Typography.captionStrong)
            .tracking(SophiieTheme.Typography.eyebrowTracking)
            .foregroundStyle(SophiieTheme.Palette.muted)
            .padding(.top, 6)
            .accessibilityAddTraits(.isHeader)
    }

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

private struct STTLanguagePicker: View {
    @ObservedObject var appState: AppState

    private static let autoTag = "__auto__"

    private var selectionTag: String {
        switch appState.sttLanguageSelection {
        case .auto: return Self.autoTag
        case .single(let code): return code
        }
    }

    private var selectionBinding: Binding<String> {
        Binding(
            get: { selectionTag },
            set: { newTag in
                appState.sttLanguageSelection = newTag == Self.autoTag
                    ? .auto
                    : .single(code: newTag)
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Language", selection: selectionBinding) {
                Text("Auto-detect").tag(Self.autoTag)
                Divider()
                ForEach(STTLanguageCatalog.all) { language in
                    Text(language.displayName).tag(language.code)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 260)

            Text(footnote(for: appState.selectedSTT, selection: appState.sttLanguageSelection))
                .font(.caption)
                .foregroundStyle(SophiieTheme.Palette.muted)
        }
    }

    private func footnote(for provider: STTProviderID, selection: STTLanguageSelection) -> String {
        switch (provider, selection) {
        case (.deepgram, .auto):
            return "Deepgram will use nova-3's multilingual mode (English, Spanish, French, German, Hindi, Russian, Portuguese, Japanese, Italian, Dutch)."
        case (.apple, .auto):
            return "Apple has no auto mode, so Whispur falls back to your system language."
        case (.openai, .auto), (.groqWhisper, .auto), (.elevenlabs, .auto), (.mistral, .auto):
            return "The provider will detect the language on each recording."
        default:
            return "Whispur will tell \(provider.displayName) which language to expect."
        }
    }
}


/// Opt-in live streaming, shown only for providers that support it.
private struct StreamingToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Stream audio while you talk", isOn: $isOn)
            Text("Text is ready sooner after you stop. If the stream fails, Whispur sends the recording instead.")
                .font(SophiieTheme.Typography.caption)
                .foregroundStyle(SophiieTheme.Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
