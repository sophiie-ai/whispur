import SwiftUI

/// An optional provider override (base URL or model) stored in UserDefaults.
/// Empty means "use the provider default", which is shown as the
/// placeholder. Saves on Return and on focus loss; no Save button.
struct ProviderOverrideField: View {
    let field: ProviderDescriptor.OverrideField
    let providerName: String

    @State private var value = ""
    @FocusState private var isFocused: Bool

    private var trimmed: String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @State private var stored = ""

    /// The registry ignores a base URL that isn't http(s), so say so instead
    /// of letting the user think it took effect.
    private var isIgnoredURL: Bool {
        field.kind == .baseURL && !trimmed.isEmpty && ProviderRegistry.normalizedBaseURL(trimmed) == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(field.label)
                    .font(SophiieTheme.Typography.captionStrong)
                    .foregroundStyle(SophiieTheme.Palette.muted)
                    .accessibilityHidden(true)

                Spacer()

                if !stored.isEmpty {
                    Button("Reset to default") {
                        value = ""
                        stored = ""
                        UserDefaults.standard.removeObject(forKey: field.storageKey)
                    }
                    .buttonStyle(.plain)
                    .font(SophiieTheme.Typography.caption)
                    .foregroundStyle(SophiieTheme.Palette.interactive)
                    .accessibilityLabel("Reset \(providerName) \(field.label.lowercased()) to default")
                }
            }

            TextField(field.defaultValue, text: $value)
                .textFieldStyle(.plain)
                .font(SophiieTheme.Typography.mono)
                .autocorrectionDisabled(true)
                .textContentType(field.kind == .baseURL ? .URL : nil)
                .focused($isFocused)
                .onSubmit(commit)
                .sophiieField(isFocused: isFocused)
                .accessibilityLabel("\(providerName) \(field.label)")
                .accessibilityHint("Leave empty to use \(field.defaultValue)")

            if isIgnoredURL {
                Text("Not an http or https URL, so Whispur keeps using the default.")
                    .font(SophiieTheme.Typography.caption)
                    .foregroundStyle(SophiieTheme.Palette.warning)
            }
        }
        .onAppear {
            stored = UserDefaults.standard.string(forKey: field.storageKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            value = stored
        }
        .onChange(of: isFocused) { wasFocused, focused in
            if wasFocused && !focused { commit() }
        }
    }

    private func commit() {
        guard trimmed != stored else { return }
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: field.storageKey)
        } else {
            UserDefaults.standard.set(trimmed, forKey: field.storageKey)
        }
        stored = trimmed
        value = trimmed
    }
}
