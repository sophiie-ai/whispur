import SwiftUI

/// Onboarding's "Languages I speak": a chip per chosen language and a menu
/// to add more. Writes the same setting as Settings → Providers.
struct OnboardingLanguagePicker: View {
    private typealias Palette = SophiieTheme.Palette

    @ObservedObject var appState: AppState
    /// The provider the footnote describes: Parakeet whenever onboarding is
    /// downloading it, even while Apple fills in.
    let provider: STTProviderID

    private var selection: STTLanguageSelection { appState.sttLanguageSelection }

    var body: some View {
        VStack(spacing: 12) {
            FlowLayout(spacing: 8, lineSpacing: 8) {
                ForEach(selection.codes, id: \.self) { code in
                    RemovableChip(
                        title: STTLanguageCatalog.displayName(for: code),
                        removeLabel: "Remove \(STTLanguageCatalog.displayName(for: code))"
                    ) {
                        set(code, on: false)
                    }
                }
                Menu {
                    ForEach(STTLanguageCatalog.all) { language in
                        Toggle(language.displayName, isOn: binding(for: language.code))
                    }
                } label: {
                    Label(selection.isAuto ? "Choose a language" : "Add a language", systemImage: "plus")
                }
                .menuStyle(.button)
                .fixedSize()
                .accessibilityLabel("Add a language")
            }
            .frame(maxWidth: 480)
            .sophiieAnimation(value: selection)

            Text(footnote)
                .font(SophiieTheme.Typography.caption)
                .foregroundStyle(Palette.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 440)
        }
    }

    /// The same note Settings shows, but only when it carries news: an
    /// uncovered language, or auto-detect.
    private var footnote: String {
        if provider == .parakeet, ParakeetLanguages.unsupported(in: selection).isEmpty, !selection.isAuto {
            return "Parakeet covers 25 European languages and works out which one you're speaking."
        }
        return SpokenLanguagesRow.footnote(for: provider, selection: selection)
    }

    private func binding(for code: String) -> Binding<Bool> {
        Binding(
            get: { selection.codes.contains(code) },
            set: { set(code, on: $0) }
        )
    }

    private func set(_ code: String, on: Bool) {
        let codes = selection.codes.filter { $0 != code } + (on ? [code] : [])
        appState.sttLanguageSelection = STTLanguageSelection(codes: codes)
    }
}
