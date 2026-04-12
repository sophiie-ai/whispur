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
                .shadow(color: .black.opacity(0.12), radius: 10, y: 6)

            VStack(spacing: 6) {
                Text("Whispur")
                    .font(.title2.weight(.semibold))

                Text("Menu-bar voice dictation for macOS")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Text(versionLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 10) {
                Text("Whispur captures speech, transcribes it, optionally cleans it up, and pastes the result back into your current app.")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)

                Link(destination: repositoryURL) {
                    Label("GitHub Repository", systemImage: "link")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }

            Divider()

            Text(copyrightLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(width: 360)
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
