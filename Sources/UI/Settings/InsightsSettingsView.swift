import AppKit
import SwiftUI

/// Insights: how much you dictate, plus a few highlights about your voice
/// (top word, most fixed word, busiest time, top app). Everything comes from
/// the counts in `DictationStats`; nothing is sent anywhere.
struct InsightsSettingsView: View {
    @ObservedObject var stats: DictationStats
    /// "Learn from my edits" is on, so fixes get counted.
    var learnsFromEdits: Bool
    var calendar: Calendar = .current

    @State private var confirmingClear = false

    static let chartDays = 30
    static let privacyNote = "Worked out on this Mac from counts only. Your words never leave it."

    var body: some View {
        SettingsPage {
            PageHeader(SettingsTab.insights.title, subtitle: SettingsTab.insights.summary) {
                if stats.insights.dictations > 0 || !stats.insights.corrections.isEmpty {
                    Button("Clear Insights") { confirmingClear = true }
                        .buttonStyle(.sophiieSecondary)
                }
            }

            SettingsSection("Usage") {
                SettingsCard { usageGrid }
                SettingsCard { chart }
            }

            SettingsSection("Your voice", footer: Self.privacyNote) {
                Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                    GridRow {
                        topWordCard
                        correctionCard
                    }
                    GridRow {
                        peakCard
                        appCard
                    }
                }
            }
        }
        .confirmationDialog("Clear your insights?", isPresented: $confirmingClear) {
            Button("Clear Insights", role: .destructive) { stats.clearInsights() }
        } message: {
            Text("Your top word, fixes, busiest time and top app start over. Word counts, your streak and history stay.")
        }
    }

    // MARK: - Usage

    private var usageGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                StatTile(value: stats.totalWords.formatted(.number), label: "Words dictated")
                StatTile(value: stats.wordsThisWeek.formatted(.number), label: "Words this week")
                StatTile(value: Self.days(stats.currentStreak), label: "Current streak")
            }
            CardDivider(leadingInset: 0).gridCellColumns(3)
            GridRow {
                StatTile(value: stats.totalDictations.formatted(.number), label: "Dictations")
                StatTile(value: Self.duration(minutes: stats.minutesSavedThisWeek), label: "Saved this week")
                StatTile(value: Self.duration(minutes: stats.minutesSavedAllTime), label: "Saved in total")
            }
        }
        .padding(.vertical, 4)
    }

    private var chart: some View {
        let days = stats.lastDays(Self.chartDays)
        let total = days.reduce(0) { $0 + $1.words }
        let peak = max(1, days.map(\.words).max() ?? 1)
        let height: CGFloat = 72
        let bar = RoundedRectangle(cornerRadius: 3, style: .continuous)

        return CardContent {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Last \(Self.chartDays) days")
                        .font(.system(size: 13.5, weight: .medium))
                    Spacer()
                    Text("\(total.formatted(.number)) words")
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(SophiieTheme.Palette.muted)
                }
                HStack(alignment: .bottom, spacing: 4) {
                    ForEach(days) { day in
                        ZStack(alignment: .bottom) {
                            bar.fill(SophiieTheme.Palette.track).frame(height: height)
                            if day.words > 0 {
                                bar.fill(SophiieTheme.Palette.highlight)
                                    .frame(height: max(4, CGFloat(day.words) / CGFloat(peak) * height))
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: height)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(total) words in the last \(Self.chartDays) days")
                HStack {
                    Text("\(Self.chartDays) days ago")
                    Spacer()
                    Text("Today")
                }
                .font(SophiieTheme.Typography.caption)
                .foregroundStyle(SophiieTheme.Palette.muted)
                .accessibilityHidden(true)
            }
        }
    }

    // MARK: - Your voice

    private var insights: DictationInsights { stats.insights }

    private var topWordCard: some View {
        let word = insights.dictationsNeeded == 0 ? insights.topWord : nil
        return HighlightCard(
            icon: "text.quote",
            label: "Most used word",
            value: word?.display,
            detail: word.map { "Said \(Self.times($0.count)). Everyday words don't count." }
                ?? (insights.dictationsNeeded > 0
                    ? Self.needMore(insights.dictationsNeeded)
                    : "Names and terms that aren't everyday words show up here.")
        )
    }

    private var correctionCard: some View {
        let word = insights.topCorrection
        return HighlightCard(
            icon: "pencil.line",
            label: "Most fixed word",
            value: word?.display,
            detail: word.map { "You fixed it \(Self.times($0.count))." }
                ?? (learnsFromEdits
                    ? "When you fix a word Whispur wrote, it's counted here. Counting started with this update."
                    : "Turn on Learn from my edits in Dictionary, and words you fix are counted here.")
        )
    }

    private var peakCard: some View {
        let slot = insights.dictationsNeeded == 0 ? insights.peakSlot : nil
        return HighlightCard(
            icon: "clock",
            label: "Busiest time",
            value: slot.map { Self.peakLabel($0, calendar: calendar) },
            detail: slot.map { "\(Self.dictationCount($0.count)) in that hour." }
                ?? Self.needMore(insights.dictationsNeeded)
        )
    }

    private var appCard: some View {
        let top = insights.dictationsNeeded == 0 ? insights.topApp : nil
        let app = top.map { AppIdentity(bundleID: $0.bundleID) }
        return HighlightCard(
            icon: "macwindow",
            appIcon: app?.icon,
            label: "Top app",
            value: app?.name,
            detail: top.map { "\(Self.percent($0.count, of: insights.dictations)) of your dictations." }
                ?? (insights.dictationsNeeded > 0
                    ? Self.needMore(insights.dictationsNeeded)
                    : "Dictate into an app and it shows up here.")
        )
    }

    // MARK: - Copy

    static func needMore(_ count: Int) -> String {
        "Dictate \(count) more \(count == 1 ? "time" : "times") to see this. Counting started with this update."
    }

    static func times(_ count: Int) -> String {
        count == 1 ? "once" : "\(count.formatted(.number)) times"
    }

    static func days(_ count: Int) -> String {
        count == 1 ? "1 day" : "\(count) days"
    }

    static func dictationCount(_ count: Int) -> String {
        count == 1 ? "1 dictation" : "\(count.formatted(.number)) dictations"
    }

    static func percent(_ part: Int, of whole: Int) -> String {
        guard whole > 0 else { return "0%" }
        return "\(Int((Double(part) / Double(whole) * 100).rounded()))%"
    }

    /// "12 min", "3 h 5 min", "0 min".
    static func duration(minutes: Int) -> String {
        guard minutes >= 60 else { return "\(minutes) min" }
        let rest = minutes % 60
        return rest == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(rest) min"
    }

    /// "Tuesdays at 10 AM".
    static func peakLabel(_ slot: DictationInsights.Slot, calendar: Calendar, locale: Locale = .current) -> String {
        let matching = DateComponents(hour: slot.hour, minute: 0, weekday: slot.weekday)
        guard let date = calendar.nextDate(after: Date(), matching: matching, matchingPolicy: .nextTime) else {
            return "\(slot.hour):00"
        }
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        return "\(date.formatted(style.weekday(.wide)))s at \(date.formatted(style.hour()))"
    }
}

/// An installed app's name and icon, from its bundle ID.
struct AppIdentity {
    let name: String
    let icon: NSImage?

    init(bundleID: String, workspace: NSWorkspace = .shared) {
        if let url = workspace.urlForApplication(withBundleIdentifier: bundleID) {
            let display = FileManager.default.displayName(atPath: url.path)
            name = display.hasSuffix(".app") ? String(display.dropLast(4)) : display
            icon = workspace.icon(forFile: url.path)
        } else {
            name = bundleID.split(separator: ".").last.map(String.init) ?? bundleID
            icon = nil
        }
    }
}

/// One number with its label, in the usage grid.
private struct StatTile: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 22, weight: .semibold).monospacedDigit())
                .tracking(SophiieTheme.Typography.titleTracking)
                .foregroundStyle(SophiieTheme.Palette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(SophiieTheme.Palette.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}

/// A "your voice" highlight: icon, label, big value (or nothing yet), and a
/// line of detail.
private struct HighlightCard: View {
    let icon: String
    var appIcon: NSImage?
    let label: String
    let value: String?
    let detail: String

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: SophiieTheme.Radius.panel, style: .continuous)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if let appIcon {
                    Image(nsImage: appIcon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: SettingsMetrics.iconTile, height: SettingsMetrics.iconTile)
                        .accessibilityHidden(true)
                } else {
                    IconTile(systemName: icon)
                }
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(SophiieTheme.Palette.muted)
            }
            if let value {
                Text(value)
                    .font(.system(size: 24, weight: .semibold))
                    .tracking(SophiieTheme.Typography.titleTracking)
                    .foregroundStyle(SophiieTheme.Palette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(value == nil ? SophiieTheme.Palette.muted : SophiieTheme.Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(SettingsMetrics.cardPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(SophiieTheme.Palette.surface, in: shape)
        .overlay(shape.strokeBorder(SophiieTheme.Palette.border, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}
