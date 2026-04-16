import SwiftUI

/// Provider configuration: API keys and active provider selection.
struct ProvidersSettingsView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                speechCard
                languagesCard
                cleanupCard
            }
            .padding(24)
        }
    }

    private var languagesCard: some View {
        PreferenceCard(
            "Preferred Language",
            detail: "Pick the language you speak. Whispur sends this as a hint to the selected STT provider. Auto-detect asks the provider to identify the language itself — best when you switch between languages.",
            icon: "character.bubble"
        ) {
            STTLanguagePicker(appState: appState)
        }
    }

    private var speechCard: some View {
        PreferenceCard(
            "Speech-to-Text",
            detail: "Pick the transcription service Whispur should call after recording.",
            icon: "waveform.badge.mic"
        ) {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Speech provider", selection: $appState.selectedSTT) {
                    ForEach(STTProviderID.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 250)

                ForEach(STTProviderID.allCases, id: \.self) { provider in
                    ProviderConfigurationCard(
                        name: provider.displayName,
                        note: provider == .apple
                            ? "Runs on-device and works without an API key."
                            : "Configure credentials in Keychain before using this provider.",
                        isActive: appState.selectedSTT == provider,
                        isConfigured: !provider.requiresAPIKey || appState.keychain.hasKeysFor(stt: provider)
                    ) {
                        if provider.requiresAPIKey {
                            ForEach(provider.keychainKeys, id: \.rawValue) { key in
                                APIKeyField(
                                    label: key.displayName,
                                    key: key,
                                    keychain: appState.keychain
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    private var cleanupCard: some View {
        PreferenceCard(
            "Cleanup Model",
            detail: "Post-processing adds punctuation, removes filler, and smooths dictation before paste.",
            icon: "wand.and.stars"
        ) {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Cleanup provider", selection: $appState.selectedLLM) {
                    ForEach(LLMProviderID.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 250)

                ForEach(LLMProviderID.allCases, id: \.self) { provider in
                    ProviderConfigurationCard(
                        name: provider.displayName,
                        note: appState.selectedLLM == provider && !appState.isSelectedLLMConfigured
                            ? "Whispur will paste raw transcripts until credentials are added."
                            : "Use this provider for transcript cleanup after transcription.",
                        isActive: appState.selectedLLM == provider,
                        isConfigured: appState.keychain.hasKeysFor(llm: provider)
                    ) {
                        ForEach(provider.keychainKeys, id: \.rawValue) { key in
                            APIKeyField(
                                label: key.displayName,
                                key: key,
                                keychain: appState.keychain
                            )
                        }
                    }
                }
            }
        }
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
                .foregroundStyle(.secondary)
        }
    }

    private func footnote(for provider: STTProviderID, selection: STTLanguageSelection) -> String {
        switch (provider, selection) {
        case (.deepgram, .auto):
            return "Deepgram will use nova-3's multilingual mode (English, Spanish, French, German, Hindi, Russian, Portuguese, Japanese, Italian, Dutch)."
        case (.apple, .auto):
            return "Apple has no auto mode — Whispur falls back to your system language."
        case (.openai, .auto), (.groqWhisper, .auto), (.elevenlabs, .auto):
            return "The provider will detect the language on each recording."
        default:
            return "Whispur will tell \(provider.displayName) which language to expect."
        }
    }
}

private struct ProviderConfigurationCard<Content: View>: View {
    let name: String
    let note: String
    let isActive: Bool
    let isConfigured: Bool
    let content: Content

    init(
        name: String,
        note: String,
        isActive: Bool,
        isConfigured: Bool,
        @ViewBuilder content: () -> Content
    ) {
        self.name = name
        self.note = note
        self.isActive = isActive
        self.isConfigured = isConfigured
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text(name)
                    .font(.headline)

                if isActive {
                    PreferenceBadge(title: "Active", tone: .good)
                }

                PreferenceBadge(
                    title: isConfigured ? "Configured" : "Needs setup",
                    tone: isConfigured ? .good : .warning
                )

                Spacer()
            }

            Text(note)
                .font(.caption)
                .foregroundStyle(.secondary)

            content
        }
        .padding(16)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
