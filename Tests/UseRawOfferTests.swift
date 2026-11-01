import AppKit
import XCTest
@testable import Whispur

final class UseRawOfferTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 1_000_000)
    private let id = UUID()

    private func offered(raw: String = "um send it friday", pasted: String = "Send it Friday.", pid: pid_t = 42, bundleID: String? = "com.apple.TextEdit") -> UseRawOffer {
        var state = UseRawOffer()
        XCTAssertTrue(state.offer(dictationID: id, raw: raw, pasted: pasted, processID: pid, bundleID: bundleID, enabled: true, now: start))
        return state
    }

    // MARK: - When to offer

    private func offers(_ raw: String, _ pasted: String) -> Bool {
        UseRawOffer.shouldOffer(raw: raw, pasted: pasted, bundleID: nil, enabled: true)
    }

    func testNoToastWhenOnlyCapitalAndPeriodWereAdded() {
        XCTAssertFalse(offers("send it friday", "Send it Friday."))
        XCTAssertFalse(offers("is it ready", "Is it ready?"))
        XCTAssertFalse(offers(" Send it. ", "Send it.\n"), "Whitespace alone")
        XCTAssertFalse(offers("its the \"final\" one - right", "It\u{2019}s the \u{201C}final\u{201D} one \u{2014} right?"), "Curly quotes and dashes")
        XCTAssertFalse(offers("", "Send it."))
    }

    func testToastWhenAFillerWasRemoved() {
        XCTAssertTrue(offers("um send it friday", "Send it Friday."))
    }

    func testToastWhenACorrectionWasApplied() {
        XCTAssertTrue(offers("send it tuesday no wednesday", "Send it Wednesday."))
    }

    func testToastWhenWordsBecameDigits() {
        XCTAssertTrue(offers("meet at ten thirty", "Meet at 10:30."))
    }

    func testNeverOffersWhenDisabledOrInATerminal() {
        XCTAssertFalse(UseRawOffer.shouldOffer(raw: "um a", pasted: "A.", bundleID: nil, enabled: false))
        XCTAssertFalse(UseRawOffer.shouldOffer(raw: "um a", pasted: "A.", bundleID: "com.apple.Terminal", enabled: true))
        XCTAssertFalse(UseRawOffer.shouldOffer(raw: "um a", pasted: "A.", bundleID: "com.mitchellh.ghostty", enabled: true))
        XCTAssertTrue(UseRawOffer.shouldOffer(raw: "um a", pasted: "A.", bundleID: "com.tinyspeck.slackmacgap", enabled: true))
    }

    func testAnUnqualifiedPasteClearsThePreviousOffer() {
        var state = offered()
        XCTAssertFalse(state.offer(dictationID: UUID(), raw: "same", pasted: "same", processID: 42, bundleID: nil, enabled: true, now: start))
        XCTAssertNil(state.current)
    }

    // MARK: - Triggering

    func testTriggerInTheSameAppReplacesWithTheRawTranscript() {
        var state = offered(raw: "  um send it friday \n")
        let result = state.trigger(frontmostProcessID: 42, now: start.addingTimeInterval(3.9))
        guard case let .replace(offer) = result else { return XCTFail("expected replace, got \(result)") }
        XCTAssertEqual(offer.dictationID, id)
        XCTAssertEqual(offer.rawTranscript, "um send it friday")
        XCTAssertEqual(offer.pastedText, "Send it Friday.")
        XCTAssertNil(state.current, "One use per offer")
        XCTAssertEqual(state.lastDismissReason, .used)
        XCTAssertEqual(state.trigger(frontmostProcessID: 42, now: start.addingTimeInterval(1)), .ignored)
    }

    func testTriggerAfterFourSecondsDoesNothing() {
        var state = offered()
        XCTAssertNotNil(state.liveOffer(at: start.addingTimeInterval(3.99)))
        XCTAssertNil(state.liveOffer(at: start.addingTimeInterval(4)))
        XCTAssertEqual(state.trigger(frontmostProcessID: 42, now: start.addingTimeInterval(4)), .ignored)
        XCTAssertEqual(state.lastDismissReason, .expired)
    }

    func testTriggerFromAnotherAppNeverReplaces() {
        var state = offered(pid: 42)
        XCTAssertEqual(state.trigger(frontmostProcessID: 99, now: start.addingTimeInterval(1)), .wrongApp)
        XCTAssertNil(state.current)
        XCTAssertEqual(state.lastDismissReason, .appChanged)
        // Coming back to the app doesn't revive it.
        XCTAssertEqual(state.trigger(frontmostProcessID: 42, now: start.addingTimeInterval(1.5)), .ignored)
        var unknownFront = offered()
        XCTAssertEqual(unknownFront.trigger(frontmostProcessID: nil, now: start), .wrongApp)
    }

    func testTypingEndsTheOffer() {
        var state = offered()
        state.keyTyped()
        XCTAssertNil(state.current)
        XCTAssertEqual(state.lastDismissReason, .typed)
        XCTAssertEqual(state.trigger(frontmostProcessID: 42, now: start.addingTimeInterval(1)), .ignored)
    }

    func testTriggerWithoutAnOfferIsIgnored() {
        var state = UseRawOffer()
        XCTAssertEqual(state.trigger(frontmostProcessID: 42, now: start), .ignored)
        state.keyTyped()
        XCTAssertNil(state.lastDismissReason)
    }

    // MARK: - Shortcut

    func testShortcutIsExactlyOptionCommandZ() {
        XCTAssertTrue(HotkeyManager.isUseRawShortcut(keyCode: 6, modifiers: [.command, .option]))
        XCTAssertTrue(HotkeyManager.isUseRawShortcut(keyCode: 6, modifiers: [.command, .option, .capsLock]))
        XCTAssertFalse(HotkeyManager.isUseRawShortcut(keyCode: 6, modifiers: [.command]), "Plain undo stays the app's")
        XCTAssertFalse(HotkeyManager.isUseRawShortcut(keyCode: 6, modifiers: [.command, .shift]), "Redo stays the app's")
        XCTAssertFalse(HotkeyManager.isUseRawShortcut(keyCode: 6, modifiers: [.command, .option, .shift]))
        XCTAssertFalse(HotkeyManager.isUseRawShortcut(keyCode: 7, modifiers: [.command, .option]))
    }

    @MainActor
    func testHotkeyManagerConsumesTheShortcutOnlyWhileArmed() {
        let manager = HotkeyManager()
        var keys: [HotkeyManager.UseRawKey] = []
        manager.onUseRawKey = { keys.append($0) }

        XCTAssertFalse(manager.handleKeyDown(keyCode: 6, modifiers: [.command, .option]), "Unarmed: the app gets ⌥⌘Z")
        manager.handleKeyUp(keyCode: 6)
        XCTAssertTrue(keys.isEmpty)

        manager.useRawWatchEnabled = true
        XCTAssertTrue(manager.handleKeyDown(keyCode: 6, modifiers: [.command, .option]))
        manager.handleKeyUp(keyCode: 6)
        XCTAssertFalse(manager.handleKeyDown(keyCode: 0, modifiers: []), "Typing passes through")
        manager.handleKeyUp(keyCode: 0)
        XCTAssertEqual(keys.map(String.init(describing:)), ["useRaw", "otherKey"])
    }

    // MARK: - Replace decision

    func testReplaceChecksTheFieldWhenItCanBeRead() {
        XCTAssertEqual(PasteReplacer.decide(pasted: "Send it Friday.", before: "Hi. Send it Friday.", after: "Hi. "), .replaced)
        XCTAssertEqual(PasteReplacer.decide(pasted: "Send it\nFriday.", before: "Send it  Friday.", after: nil), .replaced, "Whitespace-insensitive")
        XCTAssertEqual(PasteReplacer.decide(pasted: "Send it Friday.", before: "Something else", after: nil), .pastedTextNotFound)
        XCTAssertEqual(PasteReplacer.decide(pasted: "Send it Friday.", before: "Send it Friday.", after: "Send it Friday."), .undoHadNoEffect)
        XCTAssertEqual(PasteReplacer.decide(pasted: "Send it Friday.", before: nil, after: nil), .replaced, "Unreadable field: trust the undo")
    }
}

@MainActor
final class UseRawControllerTests: XCTestCase {
    private func result(raw: String = "um ship it", cleaned: String = "Ship it.") -> PipelineResult {
        PipelineResult(rawTranscript: raw, cleanedText: cleaned, sttProvider: .apple, llmProvider: .anthropic, llmModel: nil, timestamp: Date())
    }

    private func makeController(frontmost: pid_t = 7) -> (UseRawController, () -> [Bool], () -> [UseRawOffer.Offer]) {
        let controller = UseRawController()
        var watch: [Bool] = []
        var replaced: [UseRawOffer.Offer] = []
        controller.setShortcutWatch = { watch.append($0) }
        controller.frontmostProcessID = { frontmost }
        controller.replace = { offer in
            replaced.append(offer)
            return true
        }
        return (controller, { watch }, { replaced })
    }

    func testOfferArmsTheShortcutAndExpires() async throws {
        let (controller, watch, _) = makeController()
        controller.duration = .milliseconds(150)
        controller.offer(for: result(), processID: 7, bundleID: nil, enabled: true)
        XCTAssertNotNil(controller.visibleOffer)
        XCTAssertEqual(watch().last, true)

        try await Task.sleep(for: .milliseconds(400))
        XCTAssertNil(controller.visibleOffer, "Toast goes away on its own")
        XCTAssertEqual(watch().last, false, "Shortcut disarmed")
        XCTAssertEqual(controller.state.lastDismissReason, .expired)
    }

    func testTriggerSwapsAndRecordsUsedRaw() async throws {
        let (controller, watch, replaced) = makeController()
        var used: [UUID] = []
        controller.onUsedRaw = { used.append($0.dictationID) }
        let pasted = result()
        controller.offer(for: pasted, processID: 7, bundleID: nil, enabled: true)
        controller.trigger()
        XCTAssertNil(controller.visibleOffer)
        XCTAssertEqual(watch().last, false)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(replaced().map(\.rawTranscript), ["um ship it"])
        XCTAssertEqual(used, [pasted.id])

        controller.trigger()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(replaced().count, 1, "A second press does nothing")
    }

    func testFailedSwapIsNotRecorded() async throws {
        let (controller, _, _) = makeController()
        controller.replace = { _ in false }
        var used = 0
        controller.onUsedRaw = { _ in used += 1 }
        controller.offer(for: result(), processID: 7, bundleID: nil, enabled: true)
        controller.trigger()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(used, 0)
    }

    func testFocusInAnotherAppNeverSwaps() async throws {
        let (controller, _, replaced) = makeController(frontmost: 8)
        controller.offer(for: result(), processID: 7, bundleID: nil, enabled: true)
        controller.trigger()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(replaced().isEmpty)
        XCTAssertNil(controller.visibleOffer)
    }

    func testNoToastWhenOffOrUnchanged() {
        let (controller, watch, _) = makeController()
        controller.offer(for: result(), processID: 7, bundleID: nil, enabled: false)
        XCTAssertNil(controller.visibleOffer)
        controller.offer(for: result(raw: "Ship it.", cleaned: "Ship it."), processID: 7, bundleID: nil, enabled: true)
        XCTAssertNil(controller.visibleOffer)
        controller.offer(for: result(), processID: nil, bundleID: nil, enabled: true)
        XCTAssertNil(controller.visibleOffer, "No app to swap in")
        XCTAssertFalse(watch().contains(true))
    }

    func testANewDictationOrTypingEndsTheOffer() {
        let (controller, _, _) = makeController()
        controller.offer(for: result(), processID: 7, bundleID: nil, enabled: true)
        controller.dismiss(.newDictation)
        XCTAssertNil(controller.visibleOffer)

        controller.offer(for: result(), processID: 7, bundleID: nil, enabled: true)
        controller.keyTyped()
        XCTAssertNil(controller.visibleOffer)
    }

    func testHistoryRecordsUsedRaw() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("use-raw-history-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = PipelineHistoryStore(fileURL: url)
        let item = result()
        store.add(item)
        XCTAssertNil(store.item(item.id)?.usedRawAt)
        store.markUsedRaw(item.id, at: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(PipelineHistoryStore(fileURL: url).item(item.id)?.usedRawAt, Date(timeIntervalSince1970: 100), "Persisted")
    }

    func testOlderHistoryWithoutTheFieldStillLoads() throws {
        let json = #"[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","rawTranscript":"a","cleanedText":"A.","sttProvider":"apple","llmProvider":"anthropic","timestamp":0}]"#
        let items = try JSONDecoder().decode([PipelineResult].self, from: Data(json.utf8))
        XCTAssertNil(items.first?.usedRawAt)
    }
}
