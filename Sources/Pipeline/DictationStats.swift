import AppKit
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
    /// Dictations recorded since stats began. Older stats files have no
    /// count; `seedDictationCountIfMissing` fills it once from history.
    @Published private(set) var totalDictations: Int = 0
    private var hasDictationCount = false
    /// Top words, peak time, top app and corrections for the Insights page.
    /// Counted from the version that added it; older stats files start empty.
    @Published private(set) var insights = DictationInsights()

    private let isCommonWord: (String) -> Bool

    private let fileURL: URL
    private let calendar: Calendar
    private let dayFormatter: DateFormatter

    /// - Parameter fileURL: Where the stats live. Defaults to
    ///   `Application Support/Whispur/stats.json`; tests and renders pass a
    ///   temporary file.
    /// - Parameter isCommonWord: Which words the Insights top word skips.
    init(calendar: Calendar = .current, fileURL: URL? = nil, isCommonWord: @escaping (String) -> Bool = DictationStats.isEverydayWord) {
        self.calendar = calendar
        self.isCommonWord = isCommonWord

        if let fileURL {
            self.fileURL = fileURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let dir = appSupport.appendingPathComponent("Whispur", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("stats.json")
        }

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        self.dayFormatter = formatter

        load()
    }

    /// Words the Insights top word skips: ordinary dictionary words. Words
    /// the user taught the Mac's spelling checker ("Sophiie", "kubectl") are
    /// exactly the ones worth showing, so they count even though
    /// `CommonWords` treats them as common.
    static func isEverydayWord(_ word: String) -> Bool {
        let checker = NSSpellChecker.shared
        guard !checker.hasLearnedWord(word), !checker.hasLearnedWord(word.lowercased()) else { return false }
        return CommonWords.isCommon(word)
    }

    // MARK: - Recording

    /// - Parameters:
    ///   - text: The pasted text. Only its uncommon words are counted, for
    ///     the Insights top word; the text itself is never stored.
    ///   - appBundleID: The app dictated into.
    func record(wordCount: Int, text: String? = nil, appBundleID: String? = nil, at date: Date = Date()) {
        guard wordCount > 0 else { return }

        insights.record(text: text ?? "", appBundleID: appBundleID, at: date, calendar: calendar, isCommon: isCommonWord)

        let key = dayKey(for: date)
        dailyWords[key, default: 0] += wordCount
        totalWords += wordCount
        totalDictations += 1
        hasDictationCount = true
        if firstRecordedAt == nil {
            firstRecordedAt = date
        }
        save()
    }

    /// Stats written before the dictation count existed start from the
    /// number of saved history items rather than zero. No-op once a count
    /// exists.
    func seedDictationCountIfMissing(_ count: Int) {
        guard !hasDictationCount else { return }
        totalDictations = max(totalDictations, count)
        hasDictationCount = true
        save()
    }

    /// Counts a word the user fixed after Whispur wrote it.
    func recordCorrection(_ word: String) {
        insights.recordCorrection(word)
        save()
    }

    /// Forgets the Insights counts. Word totals, the streak and the
    /// dictation count stay.
    func clearInsights() {
        insights = DictationInsights()
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
        lastDays(7)
    }

    /// Words dictated on each of the last `count` days, oldest first.
    func lastDays(_ count: Int) -> [StatsDay] {
        (0 ..< count).reversed().compactMap { offset in
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
        var totalDictations: Int?
        var insights: DictationInsights?
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
            totalWords = snapshot.totalWords
            dailyWords = snapshot.dailyWords
            firstRecordedAt = snapshot.firstRecordedAt
            totalDictations = snapshot.totalDictations ?? 0
            hasDictationCount = snapshot.totalDictations != nil
            insights = snapshot.insights ?? DictationInsights()
        } catch {
            statsLogger.error("Failed to load stats: \(error.localizedDescription)")
        }
    }

    private func save() {
        let snapshot = Snapshot(
            totalWords: totalWords,
            dailyWords: dailyWords,
            firstRecordedAt: firstRecordedAt,
            totalDictations: hasDictationCount ? totalDictations : nil,
            insights: insights
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
