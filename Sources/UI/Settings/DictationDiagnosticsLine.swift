import AppKit
import SwiftUI

/// A dictation's measurements in one line, with "Copy diagnostics", which
/// copies the full record as JSON. Shown in Activity and Requests.
struct DictationDiagnosticsLine: View {
    let diagnostics: DictationDiagnostics

    @State private var copied = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "stethoscope")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(SophiieTheme.Palette.muted)
                .accessibilityHidden(true)
            Text(diagnostics.summary)
                .font(.system(size: 11.5))
                .foregroundStyle(SophiieTheme.Palette.muted)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            TextAction(title: copied ? "Copied" : "Copy diagnostics", systemImage: copied ? "checkmark" : "doc.on.doc") {
                Self.copy(diagnostics)
                copied = true
            }
            .fixedSize()
            .help("Copy this dictation's measurements as JSON. No audio and no transcript text.")
        }
        .accessibilityElement(children: .contain)
    }

    static func copy(_ diagnostics: DictationDiagnostics) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnostics.jsonString, forType: .string)
    }
}
