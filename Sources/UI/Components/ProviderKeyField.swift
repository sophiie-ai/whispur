import SwiftUI

/// One Keychain-backed key field. There is no Save button: the key saves on
/// Return, on focus loss, and shortly after a paste. Once saved, the key is
/// only ever shown masked (`••••••••abcd`) with Replace and Remove actions.
/// Non-secret values (the AWS region) stay as a plain editable field.
struct ProviderKeyField: View {
    let key: KeychainKey
    let providerName: String
    @ObservedObject var credentials: ProviderCredentials
    let focus: FocusState<String?>.Binding
    let fieldID: String
    var onSaved: () -> Void = {}

    @State private var draft = ""
    @State private var isReplacing = false
    @State private var isRevealed = false
    @State private var confirmsRemoval = false
    @State private var notice: Notice?
    @State private var pasteTask: Task<Void, Never>?
    @State private var noticeTask: Task<Void, Never>?

    private enum Notice: Equatable {
        case saved
        case removed
        case failed

        var text: String {
            switch self {
            case .saved: "Saved to Keychain"
            case .removed: "Removed from Keychain"
            case .failed: "Could not save to Keychain. Try again."
            }
        }

        var icon: String {
            self == .failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
        }

        var color: Color {
            switch self {
            case .saved: SophiieTheme.Palette.success
            case .removed: SophiieTheme.Palette.muted
            case .failed: SophiieTheme.Palette.danger
            }
        }
    }

    private var isFocused: Bool {
        focus.wrappedValue == fieldID
    }

    private var maskedValue: String? {
        guard key.isSecret, !isReplacing else { return nil }
        return credentials.displayValue(key)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(key.fieldLabel)
                .font(SophiieTheme.Typography.captionStrong)
                .foregroundStyle(SophiieTheme.Palette.muted)
                .accessibilityHidden(true)

            if let maskedValue {
                storedRow(maskedValue)
            } else {
                editRow
            }

            if let notice {
                Label(notice.text, systemImage: notice.icon)
                    .font(SophiieTheme.Typography.caption)
                    .foregroundStyle(notice.color)
                    .transition(.opacity)
            }
        }
        .sophiieAnimation(value: notice)
        .onAppear(perform: loadPlainValue)
        .onChange(of: credentials.revision) { _, _ in
            if !isFocused { loadPlainValue() }
        }
        .onChange(of: isFocused) { wasFocused, focused in
            if wasFocused && !focused { commit(leavingField: true) }
        }
        .onChange(of: draft) { previous, current in
            guard KeyEntryCommitPolicy.isLikelyPaste(previous: previous, current: current) else { return }
            pasteTask?.cancel()
            pasteTask = Task { @MainActor in
                try? await Task.sleep(for: KeyEntryCommitPolicy.pasteDebounce)
                guard !Task.isCancelled else { return }
                commit(leavingField: false)
            }
        }
        .onDisappear {
            pasteTask?.cancel()
            noticeTask?.cancel()
        }
        .confirmationDialog(
            "Remove the \(providerName) key from Keychain?",
            isPresented: $confirmsRemoval
        ) {
            Button("Remove Key", role: .destructive) {
                credentials.remove(key)
                draft = ""
                onSaved()
                show(.removed)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Whispur stops using \(providerName) until you add a key again.")
        }
    }

    // MARK: - Stored

    private func storedRow(_ masked: String) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(SophiieTheme.Palette.muted)
                    .accessibilityHidden(true)
                Text(masked)
                    .font(SophiieTheme.Typography.mono)
                    .foregroundStyle(SophiieTheme.Palette.ink)
                    .textSelection(.disabled)
                Spacer(minLength: 8)
                Text("In Keychain")
                    .font(SophiieTheme.Typography.caption)
                    .foregroundStyle(SophiieTheme.Palette.muted)
            }
            .sophiieField(isFocused: false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(storedAccessibilityLabel(masked))

            Button("Replace") {
                draft = ""
                isRevealed = false
                isReplacing = true
                DispatchQueue.main.async { focus.wrappedValue = fieldID }
            }
            .buttonStyle(.sophiieSecondary)
            .accessibilityLabel("Replace \(providerName) key")

            Button("Remove") {
                confirmsRemoval = true
            }
            .buttonStyle(.sophiieSecondary)
            .accessibilityLabel("Remove \(providerName) key")
        }
    }

    private func storedAccessibilityLabel(_ masked: String) -> String {
        let suffix = String(masked.dropFirst(KeyMasking.dots.count))
        return suffix.isEmpty
            ? "\(providerName) key saved in Keychain"
            : "\(providerName) key saved in Keychain, ending in \(suffix)"
    }

    // MARK: - Editing

    private var editRow: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                inputField
                    .textFieldStyle(.plain)
                    .font(SophiieTheme.Typography.mono)
                    .autocorrectionDisabled(true)
                    .focused(focus, equals: fieldID)
                    .onSubmit { commit(leavingField: false) }
                    .onExitCommand(perform: cancelReplace)
                    .accessibilityLabel("\(providerName) \(key.fieldLabel)")

                if key.isSecret {
                    Button {
                        isRevealed.toggle()
                    } label: {
                        Image(systemName: isRevealed ? "eye.slash" : "eye")
                            .foregroundStyle(SophiieTheme.Palette.muted)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(isRevealed ? "Hide key" : "Show key")
                    .accessibilityLabel(isRevealed ? "Hide key" : "Show key")
                }
            }
            .sophiieField(isFocused: isFocused)

            if isReplacing {
                Button("Cancel", action: cancelReplace)
                    .buttonStyle(.sophiieSecondary)
                    .accessibilityLabel("Keep the saved \(providerName) key")
            }
        }
    }

    @ViewBuilder
    private var inputField: some View {
        if key.isSecret && !isRevealed {
            SecureField(key.placeholder, text: $draft)
        } else {
            TextField(key.placeholder, text: $draft)
        }
    }

    // MARK: - Actions

    private func commit(leavingField: Bool) {
        pasteTask?.cancel()
        let stored = credentials.secret(key)
        guard KeyEntryCommitPolicy.committableValue(draft: draft, stored: stored) != nil else {
            if key.isSecret {
                // Nothing new: leaving an empty replace field returns to the
                // saved key instead of stranding an empty input.
                if leavingField && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    isReplacing = false
                }
            } else {
                loadPlainValue()
            }
            return
        }

        if credentials.save(key, draft: draft) {
            if key.isSecret {
                draft = ""
                isRevealed = false
                isReplacing = false
            }
            onSaved()
            show(.saved)
        } else {
            show(.failed)
        }
    }

    private func cancelReplace() {
        guard isReplacing else { return }
        pasteTask?.cancel()
        draft = ""
        isRevealed = false
        isReplacing = false
    }

    private func loadPlainValue() {
        guard !key.isSecret else { return }
        draft = credentials.displayValue(key) ?? ""
    }

    private func show(_ newNotice: Notice) {
        noticeTask?.cancel()
        notice = newNotice
        noticeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            notice = nil
        }
    }
}
