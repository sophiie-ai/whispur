import SwiftUI

/// Plain text field for an OpenAI-compatible base URL override stored in UserDefaults.
/// Empty value means "use the official endpoint."
struct BaseURLField: View {
    let label: String
    let storageKey: String
    let placeholder: String

    @State private var value: String = ""
    @State private var isSaved: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(SophiieTheme.Palette.muted)

            HStack(spacing: 8) {
                TextField(placeholder, text: $value)
                    .textFieldStyle(.roundedBorder)
                    .font(SophiieTheme.Typography.mono)
                    .autocorrectionDisabled(true)
                    .textContentType(.URL)

                Button(isSaved ? "Saved" : "Save") {
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    UserDefaults.standard.set(trimmed, forKey: storageKey)
                    withSophiieAnimation { isSaved = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        isSaved = false
                    }
                }
                .buttonStyle(.sophiiePrimary)
                .controlSize(.small)

                if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button {
                        value = ""
                        UserDefaults.standard.removeObject(forKey: storageKey)
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(SophiieTheme.Palette.danger)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .onAppear {
            value = UserDefaults.standard.string(forKey: storageKey) ?? ""
        }
    }
}

/// Plain text field for provider-specific string overrides stored in UserDefaults.
/// Empty value means "use the provider default."
struct ProviderTextField: View {
    let label: String
    let storageKey: String
    let placeholder: String

    @State private var value: String = ""
    @State private var isSaved: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(SophiieTheme.Palette.muted)

            HStack(spacing: 8) {
                TextField(placeholder, text: $value)
                    .textFieldStyle(.roundedBorder)
                    .font(SophiieTheme.Typography.mono)
                    .autocorrectionDisabled(true)

                Button(isSaved ? "Saved" : "Save") {
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    UserDefaults.standard.set(trimmed, forKey: storageKey)
                    withSophiieAnimation { isSaved = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        isSaved = false
                    }
                }
                .buttonStyle(.sophiiePrimary)
                .controlSize(.small)

                if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button {
                        value = ""
                        UserDefaults.standard.removeObject(forKey: storageKey)
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(SophiieTheme.Palette.danger)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .onAppear {
            value = UserDefaults.standard.string(forKey: storageKey) ?? ""
        }
    }
}
