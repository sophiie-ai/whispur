import XCTest
@testable import Whispur

final class AccessibilityRestartTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 1_000)

    private func needsRestart(trusted: Bool = true, tapInstalled: Bool = false, failures: Int, after seconds: TimeInterval, firstFailure: Bool = true) -> Bool {
        AccessibilityRestartPolicy.needsRestart(
            trusted: trusted,
            tapInstalled: tapInstalled,
            failedAttempts: failures,
            firstFailure: firstFailure ? start : nil,
            now: start.addingTimeInterval(seconds)
        )
    }

    func testRestartOnlyAfterRepeatedFailuresAcrossTheWindow() {
        // A grant whose tap keeps failing for the whole window: restart.
        XCTAssertTrue(needsRestart(failures: 4, after: 3))
        XCTAssertTrue(needsRestart(failures: 30, after: 60))
        // Too soon, however many failures.
        XCTAssertFalse(needsRestart(failures: 10, after: 2.9))
        // Long enough, but too few tries (the slow poll alone isn't evidence).
        XCTAssertFalse(needsRestart(failures: 2, after: 20))
        XCTAssertFalse(needsRestart(failures: 5, after: 5, firstFailure: false))
    }

    func testNoRestartWithoutAGrantOrOnceTheTapWorks() {
        XCTAssertFalse(needsRestart(trusted: false, failures: 10, after: 10))
        XCTAssertFalse(needsRestart(tapInstalled: true, failures: 10, after: 10))
    }

    func testFastRetriesStopOnceARestartIsSuggested() {
        XCTAssertTrue(AccessibilityRestartPolicy.shouldRetrySoon(trusted: true, tapInstalled: false, needsRestart: false))
        XCTAssertFalse(AccessibilityRestartPolicy.shouldRetrySoon(trusted: true, tapInstalled: false, needsRestart: true))
        XCTAssertFalse(AccessibilityRestartPolicy.shouldRetrySoon(trusted: true, tapInstalled: true, needsRestart: false))
        XCTAssertFalse(AccessibilityRestartPolicy.shouldRetrySoon(trusted: false, tapInstalled: false, needsRestart: false))
    }

    func testStatusResolution() {
        XCTAssertEqual(AccessibilityStatus.resolve(trusted: false, tapInstalled: false, needsRestart: false), .off)
        // A stale flag never outlives a revoked grant.
        XCTAssertEqual(AccessibilityStatus.resolve(trusted: false, tapInstalled: false, needsRestart: true), .off)
        XCTAssertEqual(AccessibilityStatus.resolve(trusted: true, tapInstalled: false, needsRestart: false), .finishing)
        XCTAssertEqual(AccessibilityStatus.resolve(trusted: true, tapInstalled: false, needsRestart: true), .needsRestart)
        // A working tap wins over a stale restart flag.
        XCTAssertEqual(AccessibilityStatus.resolve(trusted: true, tapInstalled: true, needsRestart: true), .on)
        XCTAssertTrue(AccessibilityStatus.needsRestart.isGranted)
        XCTAssertFalse(AccessibilityStatus.off.isGranted)
    }

    func testRelaunchHelperPassesPathsAsParameters() {
        let bundle = URL(fileURLWithPath: "/Applications/Whis \"pur\".app")
        let plain = AppRelauncher.arguments(pid: 42, bundle: bundle, ejecting: nil)
        XCTAssertEqual(plain.first, "-c")
        XCTAssertTrue(plain[1].hasPrefix("while /bin/kill -0 42 "))
        XCTAssertFalse(plain[1].contains("hdiutil"))
        XCTAssertFalse(plain[1].contains("Whis"), "the path must never be spliced into the script")
        XCTAssertEqual(Array(plain.dropFirst(2)), ["whispur-relaunch", bundle.path, ""])

        let ejecting = AppRelauncher.arguments(pid: 42, bundle: bundle, ejecting: "/Volumes/Whispur")
        XCTAssertTrue(ejecting[1].contains("hdiutil detach -quiet \"$2\""))
        XCTAssertEqual(ejecting.last, "/Volumes/Whispur")
    }
}
