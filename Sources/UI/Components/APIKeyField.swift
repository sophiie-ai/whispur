import SwiftUI

/// A secure text field for entering and storing API keys in the Keychain.
struct APIKeyField: View {
    let label: String
    let key: KeychainKey
    let keychain: KeychainManager

    @State private var value: String = ""
    @State private var isSaved: Bool = false
    @State private var isRevealed: Bool = false

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

                Button {
                    isRevealed.toggle()
                } label: {
                    Image(systemName: isRevealed ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)

                Button(isSaved ? "Saved" : "Save") {
                    if !value.isEmpty {
                        keychain.set(key, value: value)
                        withAnimation { isSaved = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            isSaved = false
                        }
                    }
                }
                .disabled(value.isEmpty)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                if keychain.has(key) {
                    Button {
                        keychain.delete(key)
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
            if keychain.has(key) {
                value = "••••••••••••••••"
            }
        }
    }
}
