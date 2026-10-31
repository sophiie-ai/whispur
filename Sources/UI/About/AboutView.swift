import AppKit
import SwiftUI

struct AboutView: View {
    private let repositoryURL = URL(string: "https://github.com/sophiie-ai/whispur")!

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 84, height: 84)
                .shadow(color: SophiieTheme.Shadow.tint.opacity(0.14), radius: 10, y: 6)

            VStack(spacing: 6) {
                Text("Whispur")
                    .font(.title2.weight(.semibold))
                    .tracking(SophiieTheme.Typography.titleTracking)
                    .foregroundStyle(SophiieTheme.Palette.ink)

                Text("Menu-bar voice dictation for macOS")
                    .font(.subheadline)
                    .foregroundStyle(SophiieTheme.Palette.muted)

                Text(versionLabel)
                    .font(.caption)
                    .foregroundStyle(SophiieTheme.Palette.muted)
            }

            VStack(spacing: 10) {
                Text("Whispur captures speech, transcribes it, optionally cleans it up, and pastes the result back into your current app.")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(SophiieTheme.Palette.muted)

                Link(destination: repositoryURL) {
                    Label("GitHub Repository", systemImage: "link")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.sophiiePrimary)
            }

            Divider()

            Text(copyrightLabel)
                .font(.caption)
                .foregroundStyle(SophiieTheme.Palette.muted)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(width: 360)
        .tint(SophiieTheme.Palette.accent)
    }

    private var versionLabel: String {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String

        if let build, build != version {
            return "Version \(version) (\(build))"
        }

        return "Version \(version)"
    }

    private var copyrightLabel: String {
        Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String
            ?? "© 2026 Sophiie AI Pty Ltd. All rights reserved."
    }
}
