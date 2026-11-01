import SwiftUI

/// Model menu for a speech provider. Choosing the default removes the stored
/// value, so users who never picked a model follow future default changes.
/// A model typed into the Advanced field shows up here as "Custom".
struct ProviderModelPicker: View {
    let picker: ProviderDescriptor.ModelPicker
    let providerName: String

    @AppStorage private var stored: String

    init(picker: ProviderDescriptor.ModelPicker, providerName: String) {
        self.picker = picker
        self.providerName = providerName
        _stored = AppStorage(wrappedValue: "", picker.storageKey)
    }

    private var current: String {
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? picker.defaultModel : trimmed
    }

    private var isCustom: Bool {
        !picker.options.contains { $0.id == current }
    }

    private var selection: Binding<String> {
        Binding(
            get: { current },
            set: { newValue in
                if newValue == picker.defaultModel {
                    UserDefaults.standard.removeObject(forKey: picker.storageKey)
                } else {
                    stored = newValue
                }
            }
        )
    }

    var body: some View {
        HStack {
            Text("Model")
                .font(SophiieTheme.Typography.captionStrong)
                .foregroundStyle(SophiieTheme.Palette.muted)
                .accessibilityHidden(true)
            Spacer()
            Picker("Model", selection: selection) {
                ForEach(picker.options) { option in
                    Text(option.label).tag(option.id)
                }
                if isCustom {
                    Text("Custom (\(current))").tag(current)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 240)
            .accessibilityLabel("\(providerName) model")
        }
    }
}
