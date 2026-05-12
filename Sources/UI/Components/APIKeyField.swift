import SwiftUI

/// A secure text field for entering and storing API keys in the Keychain.
struct APIKeyField: View {
    let label: String
    let key: KeychainKey
    let keychain: KeychainManager

    @State private var value: String = ""
    @State private var isSaved: Bool = false
    @State private var isRevealed: Bool = false
    @State private var hasStoredValue: Bool = false
    @FocusState private var isFocused: Bool

    private static let maskedValue = "••••••••••••••••"

    private var trimmedValue: String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isMaskedStoredValue: Bool {
        hasStoredValue && value == Self.maskedValue
    }

    private var canSave: Bool {
        !trimmedValue.isEmpty && !isMaskedStoredValue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Group {
                    if isRevealed {
                        TextField("Enter key...", text: $value)
                    } else {
                        SecureField("Enter key...", text: $value)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
                .focused($isFocused)

                Button {
                    isRevealed.toggle()
                } label: {
                    Image(systemName: isRevealed ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)

                Button(isSaved ? "Saved" : "Save") {
                    if canSave {
                        keychain.set(key, value: trimmedValue)
                        hasStoredValue = true
                        value = Self.maskedValue
                        withAnimation { isSaved = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            isSaved = false
                        }
                    }
                }
                .disabled(!canSave)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                if hasStoredValue {
                    Button {
                        keychain.delete(key)
                        hasStoredValue = false
                        value = ""
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .onAppear {
            hasStoredValue = keychain.has(key)
            value = hasStoredValue ? Self.maskedValue : ""
        }
        .onChange(of: isFocused) { _, focused in
            if focused && isMaskedStoredValue {
                value = ""
            } else if !focused && hasStoredValue && value.isEmpty {
                value = Self.maskedValue
            }
        }
    }
}
