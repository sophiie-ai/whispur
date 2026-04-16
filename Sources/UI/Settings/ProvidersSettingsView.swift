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
                appRulesCard
            }
            .padding(24)
        }
    }

    private var appRulesCard: some View {
        PreferenceCard(
            "Per-App Rules",
            detail: "Override the active providers or dictation mode when a specific app is frontmost. Ideal for \"use OpenAI in Mail, Groq in Notion, Apple in Terminal\".",
            icon: "app.badge"
        ) {
            AppProviderRulesEditor(
                rulesStore: appState.appRules,
                isEnabled: $appState.appRulesEnabled
            )
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

private struct AppProviderRulesEditor: View {
    @ObservedObject var rulesStore: AppProviderRulesStore
    @Binding var isEnabled: Bool
    @State private var showsAppPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(isOn: $isEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Enable per-app rules")
                        .font(.callout.weight(.medium))
                    Text("When off, rules below are ignored and your global providers always apply.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)

            Divider()

            if rulesStore.rules.isEmpty {
                Text("No rules yet. Add one below to override providers for specific apps.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 10) {
                    ForEach(rulesStore.rules) { rule in
                        AppRuleRow(rule: rule, rulesStore: rulesStore)
                    }
                }
                .opacity(isEnabled ? 1 : 0.55)
            }

            HStack {
                Button {
                    showsAppPicker = true
                } label: {
                    Label("Add rule for app", systemImage: "plus")
                }
                .buttonStyle(.bordered)

                Spacer()
            }
        }
        .sheet(isPresented: $showsAppPicker) {
            AppPickerSheet { pickedApp in
                let rule = AppProviderRule(
                    bundleIdentifier: pickedApp.bundleID,
                    appDisplayName: pickedApp.name
                )
                rulesStore.upsert(rule)
                showsAppPicker = false
            } onCancel: {
                showsAppPicker = false
            }
        }
    }
}

private struct AppRuleRow: View {
    let rule: AppProviderRule
    @ObservedObject var rulesStore: AppProviderRulesStore

    private var sttBinding: Binding<String> {
        Binding(
            get: { rule.sttOverride?.rawValue ?? "" },
            set: { new in
                var updated = rule
                updated.sttOverride = new.isEmpty ? nil : STTProviderID(rawValue: new)
                rulesStore.upsert(updated)
            }
        )
    }

    private var llmBinding: Binding<String> {
        Binding(
            get: { rule.llmOverride?.rawValue ?? "" },
            set: { new in
                var updated = rule
                updated.llmOverride = new.isEmpty ? nil : LLMProviderID(rawValue: new)
                rulesStore.upsert(updated)
            }
        )
    }

    private var modeBinding: Binding<String> {
        Binding(
            get: { rule.modeID?.rawValue ?? "" },
            set: { new in
                var updated = rule
                updated.modeID = new.isEmpty ? nil : DictationModeID(rawValue: new)
                rulesStore.upsert(updated)
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                AppIconView(bundleID: rule.bundleIdentifier)
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(rule.appDisplayName)
                        .font(.callout.weight(.semibold))
                    Text(rule.bundleIdentifier)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button(role: .destructive) {
                    rulesStore.remove(rule)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }

            HStack(spacing: 10) {
                Picker("Speech", selection: sttBinding) {
                    Text("Inherit").tag("")
                    Divider()
                    ForEach(STTProviderID.allCases) { provider in
                        Text(provider.displayName).tag(provider.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity)

                Picker("Cleanup", selection: llmBinding) {
                    Text("Inherit").tag("")
                    Divider()
                    ForEach(LLMProviderID.allCases) { provider in
                        Text(provider.displayName).tag(provider.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity)

                Picker("Mode", selection: modeBinding) {
                    Text("Inherit").tag("")
                    Divider()
                    ForEach(DictationModeID.allCases) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct AppIconView: NSViewRepresentable {
    let bundleID: String

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        return view
    }

    func updateNSView(_ nsView: NSImageView, context: Context) {
        if let path = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.path {
            nsView.image = NSWorkspace.shared.icon(forFile: path)
        } else {
            nsView.image = NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)
        }
    }
}

private struct DiscoveredApp: Identifiable, Hashable {
    var id: String { bundleID }
    let bundleID: String
    let name: String
    let path: String
}

private struct AppPickerSheet: View {
    let onPick: (DiscoveredApp) -> Void
    let onCancel: () -> Void
    @State private var query = ""
    @State private var apps: [DiscoveredApp] = []
    @State private var isLoading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose an app")
                .font(.headline)
            TextField("Search installed apps", text: $query)
                .textFieldStyle(.roundedBorder)

            if isLoading {
                ProgressView("Scanning /Applications…")
                    .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                List(filtered, id: \.bundleID) { app in
                    Button {
                        onPick(app)
                    } label: {
                        HStack(spacing: 10) {
                            AppIconView(bundleID: app.bundleID)
                                .frame(width: 22, height: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(app.name).font(.callout)
                                Text(app.bundleID)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.inset)
                .frame(minHeight: 260)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .frame(width: 440)
        .task {
            apps = await InstalledAppsScanner.scan()
            isLoading = false
        }
    }

    private var filtered: [DiscoveredApp] {
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return apps }
        return apps.filter {
            $0.name.lowercased().contains(trimmed) || $0.bundleID.lowercased().contains(trimmed)
        }
    }
}

private enum InstalledAppsScanner {
    static func scan() async -> [DiscoveredApp] {
        await Task.detached(priority: .userInitiated) {
            let roots = [
                "/Applications",
                "/System/Applications",
                NSHomeDirectory() + "/Applications",
            ]
            var results: [String: DiscoveredApp] = [:]
            for root in roots {
                let url = URL(fileURLWithPath: root)
                guard let entries = try? FileManager.default.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: nil
                ) else { continue }
                for entry in entries where entry.pathExtension == "app" {
                    if let bundle = Bundle(url: entry), let bid = bundle.bundleIdentifier {
                        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                            ?? entry.deletingPathExtension().lastPathComponent
                        results[bid] = DiscoveredApp(bundleID: bid, name: name, path: entry.path)
                    }
                }
            }
            return results.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }.value
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
