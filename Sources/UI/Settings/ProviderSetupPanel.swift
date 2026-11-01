import SwiftUI

/// The one key setup component for speech and cleanup providers, laid out
/// as card content. The active provider renders its setup open under the
/// card's provider picker; every other provider renders as a compact row
/// (name, status, chevron) that expands in place.
struct ProviderSetupPanel: View {
    enum Style: Equatable {
        case active
        case row(isExpanded: Bool)
    }

    let descriptor: ProviderDescriptor
    let style: Style
    let activeNote: String?
    @ObservedObject var credentials: ProviderCredentials
    @ObservedObject var tester: ProviderKeyTester
    @ObservedObject var localModel: ParakeetModelManager = .shared
    let focus: FocusState<String?>.Binding
    @Binding var isAdvancedOpen: Bool
    var onToggle: () -> Void = {}
    var onUse: (() -> Void)?

    static func fieldID(descriptor: ProviderDescriptor, key: KeychainKey) -> String {
        "\(descriptor.id).\(key.rawValue)"
    }

    private var status: ProviderSetupStatus {
        credentials.status(for: descriptor, localModel: localModel)
    }

    private var isActive: Bool { style == .active }

    private var setupNoun: String {
        descriptor.hasLocalModel ? "model setup" : "key setup"
    }

    private var showsDetails: Bool {
        switch style {
        case .active: true
        case let .row(isExpanded): isExpanded
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if showsDetails {
                details
                    .padding(.leading, isActive ? SettingsMetrics.textInset : 0)
                    .padding(.top, isActive ? 2 : 0)
                    .padding(.bottom, 14)
                    .transition(.opacity)
            }
        }
        .sophiieAnimation(value: showsDetails)
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        switch style {
        case .active:
            // The card's provider picker row is the header.
            EmptyView()
        case let .row(isExpanded):
            Button(action: onToggle) {
                SettingsRow(icon: nil, title: descriptor.name) {
                    HStack(spacing: 10) {
                        PreferenceBadge(title: status.title, tone: status.tone)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(SophiieTheme.Palette.muted)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(descriptor.name), \(status.title)")
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(isExpanded ? "Hides \(setupNoun)" : "Shows \(setupNoun)")
        }
    }

    // MARK: - Details

    private var details: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(descriptor.note)
                .font(SophiieTheme.Typography.caption)
                .foregroundStyle(SophiieTheme.Palette.muted)
                .fixedSize(horizontal: false, vertical: true)

            if let activeNote {
                Label(activeNote, systemImage: "exclamationmark.triangle.fill")
                    .font(SophiieTheme.Typography.caption)
                    .foregroundStyle(SophiieTheme.Palette.warning)
            }

            ForEach(descriptor.keys, id: \.rawValue) { key in
                ProviderKeyField(
                    key: key,
                    providerName: descriptor.name,
                    credentials: credentials,
                    focus: focus,
                    fieldID: Self.fieldID(descriptor: descriptor, key: key),
                    onSaved: { tester.invalidate(key: key) }
                )
            }

            keyCheckRow

            if descriptor.hasLocalModel {
                ParakeetModelSection(manager: localModel, isActive: isActive)
            }

            if let modelPicker = descriptor.modelPicker {
                ProviderModelPicker(picker: modelPicker, providerName: descriptor.name)
            }

            if !descriptor.overrides.isEmpty {
                advanced
            }

            if let onUse {
                Button("Use \(descriptor.name)", action: onUse)
                    .buttonStyle(.sophiieSecondary)
            }
        }
    }

    @ViewBuilder
    private var keyCheckRow: some View {
        if let check = descriptor.keyCheck {
            let hasKey = credentials.has(check.key)
            let result = tester.result(for: descriptor.id)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Button {
                    tester.run(check, descriptorID: descriptor.id, credentials: credentials)
                } label: {
                    HStack(spacing: 6) {
                        if result == .running {
                            ProgressView()
                                .controlSize(.mini)
                                .accessibilityHidden(true)
                        }
                        Text(result == .running ? "Testing" : "Test Key")
                    }
                }
                .buttonStyle(.sophiieSecondary)
                .disabled(!hasKey || result == .running)
                .help(hasKey ? "Sends one read-only request to \(descriptor.name). Nothing is transcribed or billed." : "Save a key first")
                .accessibilityLabel("Test \(descriptor.name) key")

                if let result {
                    keyCheckResult(result)
                } else if hasKey {
                    Text("One read-only request. Nothing is transcribed or billed.")
                        .font(SophiieTheme.Typography.caption)
                        .foregroundStyle(SophiieTheme.Palette.muted)
                }
            }
        } else if !descriptor.keys.isEmpty {
            Text("\(descriptor.name) has no free read-only key check, so the key is verified on your next dictation.")
                .font(SophiieTheme.Typography.caption)
                .foregroundStyle(SophiieTheme.Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func keyCheckResult(_ result: ProviderKeyTestState) -> some View {
        switch result {
        case .running:
            EmptyView()
        case let .passed(message):
            Label(message, systemImage: "checkmark.circle.fill")
                .font(SophiieTheme.Typography.caption)
                .foregroundStyle(SophiieTheme.Palette.success)
        case let .failed(message):
            Label(message, systemImage: "xmark.octagon.fill")
                .font(SophiieTheme.Typography.caption)
                .foregroundStyle(SophiieTheme.Palette.danger)
                .lineLimit(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var advanced: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withSophiieAnimation { isAdvancedOpen.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .rotationEffect(.degrees(isAdvancedOpen ? 90 : 0))
                        .accessibilityHidden(true)
                    Text("Advanced")
                        .font(SophiieTheme.Typography.captionStrong)
                }
                .foregroundStyle(SophiieTheme.Palette.inkSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Advanced settings for \(descriptor.name)")
            .accessibilityValue(isAdvancedOpen ? "Expanded" : "Collapsed")

            if isAdvancedOpen {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(descriptor.overrides) { field in
                        ProviderOverrideField(field: field, providerName: descriptor.name)
                    }
                }
                .padding(.leading, 16)
                .transition(.opacity)
            }
        }
    }
}
