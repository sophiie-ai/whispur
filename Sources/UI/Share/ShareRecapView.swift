import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Bottom-sheet style recap presented from the menu bar. Renders a stats-rich
/// card the user can copy, save, or share. The card is also the artifact we
/// expect to spread on Twitter/LinkedIn, so its look is deliberately a little
/// loud — a single big number, a streak flame, and the whispur.app footer.
struct ShareRecapView: View {
    @ObservedObject var stats: DictationStats
    @Environment(\.dismiss) private var dismiss

    @State private var status: Status = .idle

    private enum Status: Equatable {
        case idle
        case copied
        case saved(URL)
    }

    private var snapshot: RecapSnapshot {
        RecapSnapshot(
            words: stats.wordsThisWeek > 0 ? stats.wordsThisWeek : stats.totalWords,
            scope: stats.wordsThisWeek > 0 ? .week : .allTime,
            streak: stats.currentStreak,
            minutesSaved: stats.wordsThisWeek > 0 ? stats.minutesSavedThisWeek : stats.minutesSavedAllTime,
            sparkline: stats.lastSevenDays
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Share your recap")
                        .font(SophiieTheme.Typography.title)
                        .tracking(SophiieTheme.Typography.titleTracking)
                        .foregroundStyle(SophiieTheme.Palette.ink)
                    Text("A PNG you can drop into a tweet, LinkedIn post, or DM.")
                        .font(.caption)
                        .foregroundStyle(SophiieTheme.Palette.muted)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(SophiieTheme.Palette.muted)
                }
                .buttonStyle(.plain)
            }

            RecapCard(snapshot: snapshot)
                .frame(width: 360, height: 460)
                .shadow(color: SophiieTheme.Shadow.tint.opacity(0.22), radius: 24, x: 0, y: 12)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity)

            statusBanner

            HStack(spacing: 10) {
                Button {
                    copyImage()
                } label: {
                    Label("Copy image", systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.sophiiePrimary)

                Button {
                    saveImage()
                } label: {
                    Label("Save…", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.sophiieSecondary)

                Button {
                    presentSharePicker()
                } label: {
                    Label("Share…", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.sophiieSecondary)
            }
        }
        .padding(20)
        .frame(width: 440)
        .tint(SophiieTheme.Palette.accent)
    }

    @ViewBuilder
    private var statusBanner: some View {
        switch status {
        case .idle:
            EmptyView()
        case .copied:
            Label("Copied to clipboard.", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(SophiieTheme.Palette.success)
        case .saved(let url):
            Label("Saved to \(url.lastPathComponent)", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(SophiieTheme.Palette.success)
        }
    }

    // MARK: - Actions

    @MainActor
    private func renderImage() -> NSImage? {
        let renderer = ImageRenderer(content:
            RecapCard(snapshot: snapshot)
                .frame(width: 1080, height: 1350)
        )
        renderer.scale = 2
        renderer.isOpaque = true
        return renderer.nsImage
    }

    private func copyImage() {
        guard let image = renderImage() else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
        status = .copied
    }

    private func saveImage() {
        guard let image = renderImage() else { return }
        guard let data = pngData(from: image) else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = defaultFileName()
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
            status = .saved(url)
        } catch {
            NSSound.beep()
        }
    }

    private func presentSharePicker() {
        guard let image = renderImage() else { return }

        let picker = NSSharingServicePicker(items: [image])
        if let window = NSApp.keyWindow, let contentView = window.contentView {
            picker.show(relativeTo: .zero, of: contentView, preferredEdge: .minY)
        }
    }

    private func pngData(from image: NSImage) -> Data? {
        guard
            let tiff = image.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff)
        else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private func defaultFileName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return "whispur-recap-\(formatter.string(from: Date())).png"
    }
}

// MARK: - Card

struct RecapSnapshot {
    enum Scope {
        case week
        case allTime
    }

    let words: Int
    let scope: Scope
    let streak: Int
    let minutesSaved: Int
    let sparkline: [StatsDay]
}

private struct RecapCard: View {
    private typealias OnDark = SophiieTheme.Palette.OnDark

    let snapshot: RecapSnapshot

    private var headline: String {
        switch snapshot.scope {
        case .week: return "Weekly Recap"
        case .allTime: return "All-Time Recap"
        }
    }

    private var savedLabel: String {
        switch snapshot.scope {
        case .week: return "minutes saved typing this week"
        case .allTime: return "minutes saved typing"
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let scale = proxy.size.width / 360

            ZStack(alignment: .topLeading) {
                OnDark.background

                // A single soft sky glow, like the site's hero, on solid midnight.
                RadialGradient(
                    colors: [SophiieTheme.Palette.sky.opacity(0.28), SophiieTheme.Palette.sky.opacity(0)],
                    center: .topTrailing,
                    startRadius: 0,
                    endRadius: 320 * scale
                )

                VStack(alignment: .leading, spacing: 18 * scale) {
                    HStack(spacing: 10 * scale) {
                        wordmark(scale: scale)
                        Spacer()
                        Text(headline.uppercased())
                            .font(.system(size: 11 * scale, weight: .semibold))
                            .tracking(SophiieTheme.Typography.eyebrowTracking * 2 * scale)
                            .foregroundStyle(OnDark.inkSecondary)
                    }

                    Spacer(minLength: 4 * scale)

                    VStack(alignment: .leading, spacing: 6 * scale) {
                        Text(snapshot.words.formatted(.number))
                            .font(.system(size: 96 * scale, weight: .semibold))
                            .tracking(-3 * scale)
                            .foregroundStyle(OnDark.ink)
                            .minimumScaleFactor(0.5)
                            .lineLimit(1)

                        Text("words dictated")
                            .font(.system(size: 18 * scale, weight: .medium))
                            .foregroundStyle(OnDark.inkSecondary)
                    }

                    sparkline(scale: scale)

                    Rectangle()
                        .fill(OnDark.hairline)
                        .frame(height: 1)

                    HStack(spacing: 16 * scale) {
                        stat(value: "\(snapshot.streak)", caption: "day streak", emoji: snapshot.streak > 0 ? "🔥" : nil, scale: scale)
                        stat(value: "\(snapshot.minutesSaved)m", caption: savedLabel, emoji: nil, scale: scale)
                    }

                    Spacer()

                    HStack {
                        Spacer()
                        Text("whispur.app")
                            .font(.system(size: 14 * scale, weight: .semibold))
                            .foregroundStyle(OnDark.accent)
                    }
                }
                .padding(28 * scale)
            }
            .clipShape(RoundedRectangle(cornerRadius: SophiieTheme.Radius.overlay * scale, style: .continuous))
        }
    }

    private func wordmark(scale: CGFloat) -> some View {
        HStack(spacing: 8 * scale) {
            RoundedRectangle(cornerRadius: SophiieTheme.Radius.small * scale, style: .continuous)
                .fill(OnDark.ink)
                .frame(width: 22 * scale, height: 22 * scale)
                .overlay(
                    Image(systemName: "waveform")
                        .font(.system(size: 12 * scale, weight: .bold))
                        .foregroundStyle(OnDark.background)
                )
            Text("Whispur")
                .font(.system(size: 18 * scale, weight: .semibold))
                .tracking(-0.4 * scale)
                .foregroundStyle(OnDark.ink)
        }
    }

    private func sparkline(scale: CGFloat) -> some View {
        let maxValue = max(1, snapshot.sparkline.map(\.words).max() ?? 1)

        return HStack(alignment: .bottom, spacing: 8 * scale) {
            ForEach(snapshot.sparkline) { day in
                let height = max(6 * scale, CGFloat(day.words) / CGFloat(maxValue) * 60 * scale)
                VStack(spacing: 4 * scale) {
                    RoundedRectangle(cornerRadius: 4 * scale, style: .continuous)
                        .fill(day.words > 0 ? OnDark.accent : OnDark.raised)
                        .frame(width: 22 * scale, height: height)
                    Text(day.label.prefix(1).uppercased())
                        .font(.system(size: 10 * scale, weight: .medium))
                        .foregroundStyle(OnDark.muted)
                }
            }
        }
    }

    private func stat(value: String, caption: String, emoji: String?, scale: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4 * scale) {
            HStack(spacing: 6 * scale) {
                Text(value)
                    .font(.system(size: 28 * scale, weight: .semibold))
                    .tracking(-0.8 * scale)
                    .foregroundStyle(OnDark.ink)
                if let emoji {
                    Text(emoji)
                        .font(.system(size: 22 * scale))
                }
            }
            Text(caption)
                .font(.system(size: 12 * scale, weight: .medium))
                .foregroundStyle(OnDark.inkSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
