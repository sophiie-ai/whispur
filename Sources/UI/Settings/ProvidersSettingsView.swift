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
            "Preferred Languages",
            detail: "Pick up to 3 languages you speak. Whispur sends these as hints to the selected STT provider. Leave empty for auto-detect.",
            icon: "character.bubble"
        ) {
            STTLanguagesPicker(appState: appState)
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

private struct STTLanguagesPicker: View {
    @ObservedObject var appState: AppState

    private var selectedCodes: [String] {
        appState.sttLanguagesList
    }

    private var availableLanguages: [STTLanguage] {
        STTLanguageCatalog.all.filter { !selectedCodes.contains($0.code) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if selectedCodes.isEmpty {
                Text("No languages set — STT will auto-detect.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                FlowChips(codes: selectedCodes) { code in
                    appState.removeSTTLanguage(code)
                }
            }

            HStack {
                Menu {
                    ForEach(availableLanguages) { language in
                        Button(language.displayName) {
                            appState.addSTTLanguage(language.code)
                        }
                    }
                } label: {
                    Label("Add language", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(selectedCodes.count >= 3 || availableLanguages.isEmpty)

                if selectedCodes.count >= 3 {
                    Text("Maximum of 3 languages.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
        }
    }
}

private struct FlowChips: View {
    let codes: [String]
    let onRemove: (String) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(codes, id: \.self) { code in
                HStack(spacing: 6) {
                    Text(STTLanguageCatalog.displayName(for: code))
                        .font(.caption.weight(.semibold))
                    Button {
                        onRemove(code)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.orange.opacity(0.15), in: Capsule())
            }
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
