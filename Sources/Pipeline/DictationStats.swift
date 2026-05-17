import Foundation
import os

private let statsLogger = Logger(subsystem: "ai.sophiie.whispur", category: "Stats")

/// Lightweight dictation statistics persisted across launches. Drives the
/// menu-bar stats strip and the weekly recap share card.
///
/// We keep a per-day bucket of words dictated. Everything else (week totals,
/// streaks, estimated typing time saved) is derived. No transcript content is
/// stored here — only counts and dates — so this file is safe to ship alongside
/// the existing transcript history without expanding the privacy surface.
@MainActor
final class DictationStats: ObservableObject {
    /// Average sustained typing speed used to translate dictated word counts
    /// into a "minutes saved typing" estimate. Picked low enough to be
    /// defensible (Mavis Beacon, IRT studies cluster real-world prose typing
    /// between 35–45 wpm) and stable so the same dictation reports the same
    /// savings across launches.
    static let assumedTypingWPM: Double = 40

    @Published private(set) var totalWords: Int = 0
    @Published private(set) var dailyWords: [String: Int] = [:]
    @Published private(set) var firstRecordedAt: Date?

    private let fileURL: URL
    private let calendar: Calendar
    private let dayFormatter: DateFormatter

    init(calendar: Calendar = .current) {
        self.calendar = calendar

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Whispur", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("stats.json")

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        self.dayFormatter = formatter

        load()
    }

    // MARK: - Recording

    func record(wordCount: Int, at date: Date = Date()) {
        guard wordCount > 0 else { return }

        let key = dayKey(for: date)
        dailyWords[key, default: 0] += wordCount
        totalWords += wordCount
        if firstRecordedAt == nil {
            firstRecordedAt = date
        }
        save()
    }

    // MARK: - Derived metrics

    var wordsToday: Int {
        dailyWords[dayKey(for: Date())] ?? 0
    }

    var wordsThisWeek: Int {
        weekDayKeys().reduce(0) { $0 + (dailyWords[$1] ?? 0) }
    }

    var minutesSavedThisWeek: Int {
        minutesSaved(for: wordsThisWeek)
    }

    var minutesSavedAllTime: Int {
        minutesSaved(for: totalWords)
    }

    /// Length of the consecutive-day streak ending today (or yesterday if the
    /// user hasn't dictated yet today — we don't want the streak indicator to
    /// drop to zero between waking up and first use). Days are bucketed in the
    /// current calendar so DST and timezone shifts don't fragment the streak.
    var currentStreak: Int {
        var streak = 0
        var cursor = Date()

        let today = dayKey(for: cursor)
        if dailyWords[today] == nil {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: cursor) else { return 0 }
            cursor = yesterday
        }

        while dailyWords[dayKey(for: cursor)] != nil {
            streak += 1
            guard let prev = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
        }
        return streak
    }

    /// Returns the words dictated on each of the last 7 days, oldest first.
    /// Used to draw a sparkline / streak strip in the menu bar.
    var lastSevenDays: [StatsDay] {
        (0 ..< 7).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: Date()) else { return nil }
            let key = dayKey(for: date)
            let symbol = calendar.shortWeekdaySymbols[calendar.component(.weekday, from: date) - 1]
            return StatsDay(id: key, label: symbol, words: dailyWords[key] ?? 0)
        }
    }

    // MARK: - Helpers

    private func minutesSaved(for words: Int) -> Int {
        guard words > 0 else { return 0 }
        let minutes = Double(words) / Self.assumedTypingWPM
        return max(0, Int(minutes.rounded()))
    }

    private func weekDayKeys() -> [String] {
        (0 ..< 7).compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: Date()).map(dayKey(for:))
        }
    }

    private func dayKey(for date: Date) -> String {
        dayFormatter.string(from: date)
    }

    // MARK: - Persistence

    private struct Snapshot: Codable {
        var totalWords: Int
        var dailyWords: [String: Int]
        var firstRecordedAt: Date?
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
            totalWords = snapshot.totalWords
            dailyWords = snapshot.dailyWords
            firstRecordedAt = snapshot.firstRecordedAt
        } catch {
            statsLogger.error("Failed to load stats: \(error.localizedDescription)")
        }
    }

    private func save() {
        let snapshot = Snapshot(
            totalWords: totalWords,
            dailyWords: dailyWords,
            firstRecordedAt: firstRecordedAt
        )
        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            statsLogger.error("Failed to save stats: \(error.localizedDescription)")
        }
    }
}

extension String {
    /// Word count using whitespace splitting — matches the heuristic the
    /// pipeline already uses to decide whether cleanup should run.
    var whitespaceWordCount: Int {
        split { $0.isWhitespace }.count
    }
}

struct StatsDay: Identifiable, Equatable {
    let id: String
    let label: String
    let words: Int
}
