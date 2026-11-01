import XCTest
@testable import Whispur

@MainActor
final class VocabularyStoreTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "ai.sophiie.whispur.tests.vocabulary.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testMigratesPlainListAsManualTermsWithoutDates() {
        defaults.set("Claude Code\nSophiie, kubectl\n\n  .NET \nsophiie", forKey: VocabularyStore.legacyKey)

        let store = VocabularyStore(defaults: defaults)

        XCTAssertEqual(store.plainTerms, ["Claude Code", "Sophiie", "kubectl", ".NET"],
                       "Same terms, order and dedupe as the plain list the pipeline used to read")
        XCTAssertEqual(store.plainTerms, VocabularyParser.parse("Claude Code\nSophiie, kubectl\n\n  .NET \nsophiie"))
        XCTAssertTrue(store.terms.allSatisfy { $0.source == .manual && $0.addedAt == nil })
        XCTAssertEqual(store.terms.first?.note(), "Added by you")
        XCTAssertNotNil(defaults.data(forKey: VocabularyStore.termsKey), "Migration is persisted")
    }

    func testMigrationRunsOnceAndKeepsLaterEdits() {
        defaults.set("Alpha", forKey: VocabularyStore.legacyKey)
        let first = VocabularyStore(defaults: defaults)
        first.add("Beta")

        // A stale legacy value must not re-migrate over the stored terms.
        defaults.set("Alpha\nGamma", forKey: VocabularyStore.legacyKey)
        let reloaded = VocabularyStore(defaults: defaults)
        XCTAssertEqual(reloaded.plainTerms, ["Beta", "Alpha"])
    }

    func testEmptyStoreWithNoLegacyList() {
        let store = VocabularyStore(defaults: defaults)
        XCTAssertTrue(store.terms.isEmpty)
        XCTAssertEqual(store.plainTerms, [])
    }

    func testAddRecordsSourceAndDateAndDedupes() {
        let store = VocabularyStore(defaults: defaults)
        let date = Date(timeIntervalSince1970: 1_793_500_000)

        XCTAssertTrue(store.add("  Whispur ", at: date))
        XCTAssertTrue(store.add("Sophiie", source: .learned(original: "Sophie"), at: date))
        XCTAssertFalse(store.add("whispur"), "Case-insensitive duplicate")
        XCTAssertFalse(store.add("   "), "Empty")

        XCTAssertEqual(store.plainTerms, ["Sophiie", "Whispur"], "Newest first")
        let learned = store.terms[0]
        XCTAssertTrue(learned.isLearned)
        XCTAssertEqual(learned.source, .learned(original: "Sophie"))
        XCTAssertEqual(learned.addedAt, date)
        XCTAssertEqual(learned.note(dateFormat: { _ in "2 Nov" }), "Learned from your edit of \u{201C}Sophie\u{201D} \u{00B7} 2 Nov")
        XCTAssertEqual(store.terms[1].note(dateFormat: { _ in "2 Nov" }), "Added by you \u{00B7} 2 Nov")
    }

    func testPersistsSourcesAndMirrorsThePlainList() {
        let store = VocabularyStore(defaults: defaults)
        store.add("Whispur")
        store.add("kubectl", source: .learned(original: "cube cuddle"))

        XCTAssertEqual(defaults.string(forKey: VocabularyStore.legacyKey), "kubectl\nWhispur",
                       "Older builds still read the same terms")

        let reloaded = VocabularyStore(defaults: defaults)
        XCTAssertEqual(reloaded.terms, store.terms)

        reloaded.remove(id: reloaded.terms[0].id)
        XCTAssertEqual(reloaded.plainTerms, ["Whispur"])
        XCTAssertEqual(defaults.string(forKey: VocabularyStore.legacyKey), "Whispur")
    }

    func testFilterBySourceAndQuery() {
        let store = VocabularyStore(defaults: defaults)
        store.add("Whispur")
        store.add("Sophiie", source: .learned(original: "Sophie"))
        store.add("PlanetScale")

        XCTAssertEqual(VocabularyStore.filter(store.terms, query: "", filter: .all).map(\.text), ["PlanetScale", "Sophiie", "Whispur"])
        XCTAssertEqual(VocabularyStore.filter(store.terms, query: "", filter: .learned).map(\.text), ["Sophiie"])
        XCTAssertEqual(VocabularyStore.filter(store.terms, query: "", filter: .manual).map(\.text), ["PlanetScale", "Whispur"])
        XCTAssertEqual(VocabularyStore.filter(store.terms, query: " planet ", filter: .all).map(\.text), ["PlanetScale"])
        XCTAssertEqual(VocabularyStore.filter(store.terms, query: "planet", filter: .learned).map(\.text), [])
    }

    func testSnippetIsShortAndOneLine() {
        XCTAssertEqual(VocabularyTerm.snippet("cube\ncuddle"), "cube cuddle")
        let long = String(repeating: "word ", count: 20)
        let snippet = VocabularyTerm.snippet(long)
        XCTAssertLessThanOrEqual(snippet.count, VocabularyTerm.snippetLimit)
        XCTAssertTrue(snippet.hasSuffix("\u{2026}"))
    }
}
