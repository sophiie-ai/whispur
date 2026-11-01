@testable import Whispur
import XCTest

final class VoiceCommandsTests: XCTestCase {
    private func apply(_ text: String) -> String {
        VoiceCommands.apply(to: text)
    }

    // MARK: - Scratch that

    func testScratchThatRemovesThePreviousSentence() {
        XCTAssertEqual(apply("Send the quote to Alice. Scratch that. Send it to Bob."), "Send it to Bob.")
        XCTAssertEqual(apply("Hi Sam. Send it to Alice. Delete that. Send it to Bob."), "Hi Sam. Send it to Bob.")
        XCTAssertEqual(apply("Send it to Alice, scratch that, send it to Bob."), "Send it to Bob.")
    }

    func testScratchThatAtTheEndRemovesItsSentence() {
        XCTAssertEqual(apply("Ship it Friday. Send the quote to Alice scratch that."), "Ship it Friday.")
        XCTAssertEqual(apply("Ship it Friday. Send the quote to Alice, scratch that"), "Ship it Friday.")
        XCTAssertEqual(apply("Ship it Friday. Oh sorry, scratch that."), "")
        XCTAssertEqual(apply("Ship it Friday. Actually delete that."), "")
    }

    func testScratchingTheOnlySentenceLeavesNothing() {
        XCTAssertEqual(apply("Send the quote to Alice. Scratch that."), "")
        XCTAssertEqual(apply("send the quote to alice scratch that"), "")
    }

    func testScratchThatMidPhraseIsContent() {
        let kept = [
            "She said scratch that and then closed the notebook.",
            "she said scratch that and then closed the notebook",
            "I'll scratch that idea from the list.",
            "Can you delete that file for me?",
            "We should delete that.",
            "Please delete that.",
            "She said scratch that.",
            "Scratch that, I'll do it myself.",
            "Delete that.",
            "Oh sorry, scratch that.",
            "The word \"scratch that\" is a command.",
        ]
        for text in kept {
            XCTAssertEqual(apply(text), text, text)
        }
    }

    func testSuccessiveScratches() {
        XCTAssertEqual(apply("One. Two. Scratch that. Scratch that. Three."), "Three.")
        XCTAssertEqual(apply("One. Two. Scratch that. Three. Delete that. Four."), "One. Four.")
    }

    // MARK: - New line and new paragraph

    func testNewLineAndParagraph() {
        XCTAssertEqual(apply("Hello Maya, new line, the build passed."), "Hello Maya\nThe build passed.")
        XCTAssertEqual(apply("To do. New line. Ship the fix. New line. Review the PR."),
                       "To do.\nShip the fix.\nReview the PR.")
        XCTAssertEqual(apply("Thanks for the update. New paragraph. The next release is Friday."),
                       "Thanks for the update.\n\nThe next release is Friday.")
        XCTAssertEqual(apply("Hello Maya newline."), "Hello Maya")
        XCTAssertEqual(apply("Hi team new paragraph."), "Hi team")
        XCTAssertEqual(apply("New line. Hello."), "Hello.")
    }

    func testNewLineMidPhraseIsContent() {
        let kept = [
            "We need a new line of products.",
            "we need a new line of products",
            "We need a new line.",
            "Start a new paragraph.",
            "Add a newline at the end of the file.",
            "Print a newline.",
            "todo new line ship the fix",
            "The new paragraph reads better.",
            "This is the new line, I think.",
        ]
        for text in kept {
            XCTAssertEqual(apply(text), text, text)
        }
    }

    func testTextWithoutCommandsIsUnchanged() {
        for text in ["Book the room for Tuesday.", "Scratch the surface.", "Newlines are tricky.", ""] {
            XCTAssertEqual(apply(text), text)
        }
    }

    // MARK: - Restoring line breaks after cleanup

    func testRestoreLineBreaksPutsBackCollapsedBreaks() {
        let transcript = "thanks for the update\n\nthe next release is friday"
        XCTAssertEqual(
            VoiceCommands.restoreLineBreaks(in: "Thanks for the update.\nThe next release is Friday.", from: transcript),
            "Thanks for the update.\n\nThe next release is Friday."
        )
        XCTAssertEqual(
            VoiceCommands.restoreLineBreaks(in: "Hello Maya,\n\n\nThe build passed.", from: "hello maya\nthe build passed"),
            "Hello Maya,\nThe build passed."
        )
    }

    func testRestoreLineBreaksLeavesReshapedCleanupAlone() {
        // Merged lines, or a list the model built: block counts differ.
        XCTAssertEqual(
            VoiceCommands.restoreLineBreaks(in: "Hello Maya, the build passed.", from: "hello maya\nthe build passed"),
            "Hello Maya, the build passed."
        )
        XCTAssertEqual(
            VoiceCommands.restoreLineBreaks(in: "List:\n- Eggs\n- Milk", from: "list\nbullet eggs bullet milk"),
            "List:\n- Eggs\n- Milk"
        )
        // No breaks in the transcript: nothing to restore.
        XCTAssertEqual(VoiceCommands.restoreLineBreaks(in: "A\nB", from: "a b"), "A\nB")
    }
}
