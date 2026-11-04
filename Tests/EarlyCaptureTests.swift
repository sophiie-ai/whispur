import XCTest
@testable import Whispur

/// The microphone starts at Fn key-down and is kept only if the press
/// becomes a recording; taps and chords discard it.
final class EarlyCaptureTests: XCTestCase {

    func testEveryBeginGetsOneResolution() {
        var capture = EarlyCapture()
        XCTAssertEqual(capture.waitStarted(), .begin)
        XCTAssertNil(capture.waitStarted(), "a second press can't open another")
        XCTAssertEqual(capture.waitEnded(startedRecording: false), .discard)
        XCTAssertNil(capture.waitEnded(startedRecording: false), "already resolved")

        XCTAssertEqual(capture.waitStarted(), .begin)
        XCTAssertNil(capture.waitEnded(startedRecording: true), "the recording keeps it")
        XCTAssertFalse(capture.isOpen)
    }

    // MARK: - Hold (Fn with the arm threshold)

    @MainActor
    private func makeKeyboard(
        hold: ShortcutBinding? = .fnKey,
        tapOrHold: ShortcutBinding? = nil,
        threshold: TimeInterval = 0.05
    ) -> (FakeKeyboard, () -> [String]) {
        let manager = HotkeyManager()
        manager.holdArmThreshold = threshold
        manager.holdBinding = hold
        manager.toggleBinding = nil
        manager.tapOrHoldVetoWindow = threshold
        manager.tapOrHoldThreshold = 10
        manager.tapOrHoldBinding = tapOrHold
        var log: [String] = []
        manager.onEvent = { log.append(String(describing: $0)) }
        manager.onEarlyCapture = { log.append("capture." + String(describing: $0)) }
        return (FakeKeyboard(manager: manager), { log })
    }

    @MainActor
    private func wait(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    @MainActor
    func testHoldKeepsTheCaptureFromKeyDown() {
        let (keyboard, log) = makeKeyboard()
        keyboard.press(.fn)
        XCTAssertEqual(log(), ["capture.begin"], "the mic starts at key-down")
        wait(0.15)
        keyboard.release(.fn)
        XCTAssertEqual(log(), ["capture.begin", "holdActivated", "holdDeactivated"])
    }

    @MainActor
    func testTapAndChordDiscardSilently() {
        let (keyboard, log) = makeKeyboard()
        keyboard.press(.fn)
        keyboard.release(.fn)
        keyboard.press(.fn)
        keyboard.manager.handleKeyDown(keyCode: 51) // Fn+Delete
        keyboard.manager.handleKeyUp(keyCode: 51)
        wait(0.15)
        keyboard.release(.fn)
        XCTAssertEqual(log(), ["capture.begin", "capture.discard", "capture.begin", "capture.discard"])
    }

    @MainActor
    func testDisablingShortcutsDiscardsAnOpenCapture() {
        let (keyboard, log) = makeKeyboard(threshold: 10)
        keyboard.press(.fn)
        keyboard.manager.isEnabled = false
        XCTAssertEqual(log(), ["capture.begin", "capture.discard"])
    }

    // MARK: - Tap or hold

    @MainActor
    func testTapOrHoldKeepsTapsAndDiscardsChords() {
        let (keyboard, log) = makeKeyboard(hold: nil, tapOrHold: .fnKey)
        keyboard.press(.fn)
        keyboard.release(.fn)
        XCTAssertEqual(log(), ["capture.begin", "toggleActivated", "toggleDeactivated"], "a tap starts locked and keeps it")

        keyboard.manager.setShortcutSessionActive(false)
        keyboard.press(.fn)
        keyboard.manager.handleKeyDown(keyCode: 123) // Fn+Left arrow
        keyboard.manager.handleKeyUp(keyCode: 123)
        keyboard.release(.fn)
        XCTAssertEqual(Array(log().suffix(2)), ["capture.begin", "capture.discard"])
    }

    // MARK: - Short dictations

    /// 85 ms buffers at 48 kHz: quiet room, then a short word.
    private func metrics(loudBuffers: Int, quietBuffers: Int = 6) -> RecordingMetrics {
        let quiet = BufferMetric(frameCount: 4096, rms: 0.002)
        let loud = BufferMetric(frameCount: 4096, rms: 0.08)
        let buffers = [quiet] + Array(repeating: quiet, count: quietBuffers) + Array(repeating: loud, count: loudBuffers)
        return RecordingMetrics(sampleRate: 48_000, totalFrames: Int64(buffers.count * 4096), buffers: buffers)
    }

    func testOneShortWordIsTranscribed() {
        XCTAssertTrue(DictationPipeline.recordingHasSpeech(metrics: metrics(loudBuffers: 2)), "a ~170 ms word")
    }

    func testOneClickIsStillSkipped() {
        XCTAssertFalse(DictationPipeline.recordingHasSpeech(metrics: metrics(loudBuffers: 1)))
        XCTAssertFalse(DictationPipeline.recordingHasSpeech(metrics: metrics(loudBuffers: 0)))
    }
}
