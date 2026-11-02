import SwiftUI

/// Download, progress, memory and delete for the Parakeet model, inside its
/// provider panel.
struct ParakeetModelSection: View {
    @ObservedObject var manager: ParakeetModelManager
    /// Parakeet is the selected speech provider.
    let isActive: Bool

    @State private var confirmingDelete = false

    private var spec: ParakeetModelSpec { manager.spec }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch manager.downloadState {
            case .notDownloaded:
                notDownloaded
            case let .downloading(fraction, isPreparing):
                downloading(fraction: fraction, isPreparing: isPreparing)
            case let .failed(message):
                failed(message)
            case let .installed(bytes):
                installed(bytesOnDisk: bytes)
            case .waitingForNetwork:
                waitingForNetwork
            }

            if isActive, !manager.isInstalled {
                Text(ParakeetDownloadCopy.fallbackNote)
                    .font(SophiieTheme.Typography.caption)
                    .foregroundStyle(SophiieTheme.Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("\(spec.attribution) License: \(spec.license).")
                .font(SophiieTheme.Typography.caption)
                .foregroundStyle(SophiieTheme.Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .confirmationDialog(
            "Delete the \(spec.displayName) model?",
            isPresented: $confirmingDelete
        ) {
            Button("Delete Model", role: .destructive) {
                Task { await manager.delete() }
            }
        } message: {
            Text(isActive
                ? "Apple's on-device recognition transcribes until you download it again."
                : "You can download it again any time.")
        }
    }

    // MARK: - States

    private var notDownloaded: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(spec.displayName) is a one-time download of about \(Self.size(spec.downloadBytes)) from Hugging Face. It stays on this Mac in Application Support.")
                .font(SophiieTheme.Typography.caption)
                .foregroundStyle(SophiieTheme.Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Download Model (\(Self.size(spec.downloadBytes)))") { manager.download() }
                .buttonStyle(.sophiiePrimary)
                .accessibilityLabel("Download the \(spec.displayName) model, \(Self.size(spec.downloadBytes))")
        }
    }

    private func downloading(fraction: Double, isPreparing: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if isPreparing {
                ProgressView()
                    .progressViewStyle(.linear)
                    .accessibilityLabel("Preparing the model")
            } else {
                ProgressView(value: fraction)
                    .accessibilityLabel("Downloading the model")
                    .accessibilityValue("\(Int(fraction * 100)) percent")
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(isPreparing
                    ? "Preparing the model for the Neural Engine. This can take a minute the first time."
                    : "Downloading \(Int(fraction * 100))% of \(Self.size(spec.downloadBytes))")
                    .font(SophiieTheme.Typography.caption)
                    .foregroundStyle(SophiieTheme.Palette.inkSecondary)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Cancel") { manager.cancelDownload() }
                    .buttonStyle(.sophiieSecondary)
                    .accessibilityLabel("Cancel the model download")
            }
        }
    }

    private var waitingForNetwork: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Label("Waiting for Wi-Fi. This network is metered or in Low Data Mode, so the \(Self.size(spec.downloadBytes)) download waits.", systemImage: "wifi.exclamationmark")
                .font(SophiieTheme.Typography.caption)
                .foregroundStyle(SophiieTheme.Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Download Now") { manager.download() }
                .buttonStyle(.sophiieSecondary)
                .accessibilityLabel("Download the \(spec.displayName) model now")
        }
    }

    private func failed(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Label(message, systemImage: "xmark.octagon.fill")
                .font(SophiieTheme.Typography.caption)
                .foregroundStyle(SophiieTheme.Palette.danger)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Retry") { manager.download() }
                .buttonStyle(.sophiieSecondary)
                .accessibilityLabel("Retry the model download")
        }
    }

    private func installed(bytesOnDisk: Int64) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Label("\(spec.displayName) downloaded, \(Self.size(bytesOnDisk)) on disk.", systemImage: "checkmark.circle.fill")
                    .font(SophiieTheme.Typography.caption)
                    .foregroundStyle(SophiieTheme.Palette.success)
                Text(memoryLine)
                    .font(SophiieTheme.Typography.caption)
                    .foregroundStyle(SophiieTheme.Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button("Delete Model") { confirmingDelete = true }
                .buttonStyle(.sophiieSecondary)
                .accessibilityLabel("Delete the \(spec.displayName) model")
        }
    }

    private var memoryLine: String {
        switch manager.loadState {
        case .unloaded:
            isActive ? "Loads into memory in the background." : "Loads into memory while Parakeet is your speech provider."
        case .loading:
            "Loading into memory."
        case let .loaded(report):
            "Loaded in \(String(format: "%.1f", report.seconds)) s. Whispur's memory grew by about \(Self.size(report.footprintBytes))."
        case let .failed(message):
            "Couldn't load the model: \(message)"
        }
    }

    static func size(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useMB, .useGB]
        return formatter.string(fromByteCount: bytes)
    }
}

/// One line on the model download for onboarding and Get started, shown
/// while Parakeet is the speech provider and its model isn't here. Never
/// blocks anything; a failed download gets a Retry.
struct ParakeetDownloadStatusLine: View {
    @ObservedObject var manager: ParakeetModelManager

    var body: some View {
        if let line = ParakeetDownloadCopy.line(for: manager.downloadState) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(SophiieTheme.Palette.muted)
                Text(line)
                    .font(SophiieTheme.Typography.caption)
                    .foregroundStyle(SophiieTheme.Palette.inkSecondary)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                if let action {
                    Button(action.title, action: action.run)
                        .buttonStyle(.sophiieSecondary)
                        .controlSize(.small)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var icon: String {
        switch manager.downloadState {
        case .failed: "exclamationmark.triangle"
        case .waitingForNetwork: "wifi.exclamationmark"
        default: "arrow.down.circle"
        }
    }

    private var action: (title: String, run: () -> Void)? {
        switch manager.downloadState {
        case .failed: ("Retry", { manager.download() })
        case .notDownloaded: ("Download", { manager.download() })
        default: nil
        }
    }
}
