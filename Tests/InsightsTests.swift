import XCTest
@testable import Whispur

final class InsightsTests: XCTestCase {
    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// 2026-11-03 is a Tuesday (weekday 3).
    private static func date(day: Int = 3, hour: Int) -> Date {
        utc.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!
    }

    private static let common: Set<String> = ["the", "ask", "to", "call", "back", "push", "build"]

    private func record(_ insights: inout DictationInsights, _ text: String, app: String? = nil, hour: Int = 9, day: Int = 3) {
        insights.record(text: text, appBundleID: app, at: Self.date(day: day, hour: hour), calendar: Self.utc) {
            Self.common.contains($0.lowercased())
        }
    }

    func testTopWordSkipsCommonWordsAndJunk() {
        var insights = DictationInsights()
        record(&insights, "Ask Sophiie to call the plumber back.")
        record(&insights, "push the build to sophiie, see https://x.io/a a@b.co 42 x")
        record(&insights, "the the the the")
        XCTAssertEqual(insights.topWord, .init(display: "sophiie", count: 2), "Counted case-insensitively, latest spelling kept")
        XCTAssertNil(insights.words["the"])
        XCTAssertNil(insights.words["42"])
        XCTAssertNil(insights.words["x"])
        XCTAssertTrue(insights.words.keys.allSatisfy { !$0.contains("/") && !$0.contains("@") })
    }

    func testPeakSlotAndTopApp() {
        var insights = DictationInsights()
        XCTAssertNil(insights.peakSlot)
        XCTAssertNil(insights.topApp)
        record(&insights, "a", app: "com.apple.Safari", hour: 16, day: 2)
        record(&insights, "a", app: "com.apple.mail", hour: 10)
        record(&insights, "a", app: "com.apple.mail", hour: 10)
        record(&insights, "a", app: nil, hour: 16, day: 2)
        // Tie on slots: Monday 16:00 comes before Tuesday 10:00 in the week.
        XCTAssertEqual(insights.peakSlot, .init(weekday: 2, hour: 16, count: 2))
        XCTAssertEqual(insights.topApp?.bundleID, "com.apple.mail")
        XCTAssertEqual(insights.topApp?.count, 2)
        XCTAssertEqual(insights.dictations, 4)
        XCTAssertEqual(insights.dictationsNeeded, DictationInsights.minimumDictations - 4)
    }

    func testWordTableIsBounded() {
        var insights = DictationInsights()
        record(&insights, "Kubernetes Kubernetes")
        for chunk in stride(from: 0, to: DictationInsights.wordLimit + 50, by: 50) {
            record(&insights, (chunk ..< chunk + 50).map { "zq\($0)" }.joined(separator: " "))
        }
        XCTAssertLessThanOrEqual(insights.words.count, DictationInsights.wordLimit)
        XCTAssertEqual(insights.topWord?.display, "Kubernetes", "The frequent word survives pruning")
    }

    func testCorrectionsCountTrimmedWords() {
        var insights = DictationInsights()
        insights.recordCorrection("Sophie,")
        insights.recordCorrection("sophie")
        insights.recordCorrection("  ")
        insights.recordCorrection("wispur")
        XCTAssertEqual(insights.topCorrection, .init(display: "sophie", count: 2))
        XCTAssertEqual(insights.corrections.count, 2)
    }

    @MainActor
    func testOldStatsFileLoadsAndInsightsPersist() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("stats-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"totalWords":40,"dailyWords":{"2026-11-01":40},"totalDictations":3}"#.utf8).write(to: url)

        let stats = DictationStats(calendar: Self.utc, fileURL: url) { Self.common.contains($0.lowercased()) }
        XCTAssertEqual(stats.totalWords, 40)
        XCTAssertEqual(stats.insights, DictationInsights())

        stats.record(wordCount: 4, text: "call Sophiie back", appBundleID: "com.apple.mail", at: Self.date(hour: 9))
        stats.recordCorrection("Sophie")
        let reloaded = DictationStats(calendar: Self.utc, fileURL: url)
        XCTAssertEqual(reloaded.totalWords, 44)
        XCTAssertEqual(reloaded.insights.topWord?.display, "Sophiie")
        XCTAssertEqual(reloaded.insights.topApp?.bundleID, "com.apple.mail")
        XCTAssertEqual(reloaded.insights.topCorrection?.display, "Sophie")

        reloaded.clearInsights()
        let cleared = DictationStats(calendar: Self.utc, fileURL: url)
        XCTAssertEqual(cleared.insights, DictationInsights())
        XCTAssertEqual(cleared.totalWords, 44, "Clearing insights keeps the word count")
    }

    func testCopy() {
        XCTAssertEqual(InsightsSettingsView.needMore(1), "Dictate 1 more time to see this. Counting started with this update.")
        XCTAssertEqual(InsightsSettingsView.duration(minutes: 125), "2 h 5 min")
        XCTAssertEqual(InsightsSettingsView.duration(minutes: 45), "45 min")
        XCTAssertTrue(InsightsSettingsView.peakLabel(.init(weekday: 2, hour: 16, count: 1), calendar: Self.utc).hasPrefix("Mondays at 4"))
    }
}
