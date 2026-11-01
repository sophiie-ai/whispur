import CoreGraphics
import XCTest
@testable import Whispur

final class PermissionGuideTests: XCTestCase {

    // MARK: - List names per macOS version

    func testAccessibilityListNameFollowsTheMacOS27Rename() {
        XCTAssertEqual(GuidedPermission.listName(.accessibility, macOSMajor: 14), "Accessibility")
        XCTAssertEqual(GuidedPermission.listName(.accessibility, macOSMajor: 26), "Accessibility")
        XCTAssertEqual(GuidedPermission.listName(.accessibility, macOSMajor: 27), "Device Control and Data Access")
        XCTAssertEqual(GuidedPermission.listName(.accessibility, macOSMajor: 28), "Device Control and Data Access")
        XCTAssertEqual(GuidedPermission.listName(.microphone, macOSMajor: 27), "Microphone")
    }

    func testPaneURLsAndDragRules() {
        XCTAssertEqual(
            GuidedPermission.accessibility.settingsURL.absoluteString,
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"
        )
        XCTAssertEqual(
            GuidedPermission.microphone.settingsURL.absoluteString,
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone"
        )
        XCTAssertTrue(GuidedPermission.accessibility.isDraggable)
        // The Microphone list only holds apps that asked: switch on, no drag.
        XCTAssertFalse(GuidedPermission.microphone.isDraggable)
        XCTAssertEqual(GuidedPermission.accessibility.instruction(appName: "Whispur"), "Drag Whispur into the list, then switch it on.")
        XCTAssertTrue(GuidedPermission.microphone.instruction(appName: "Whispur").hasPrefix("Switch on Whispur in the Microphone list"))
    }

    // MARK: - Finding the System Settings window

    private func window(owner: String, layer: Int = 0, x: CGFloat = 0, y: CGFloat = 0, width: CGFloat, height: CGFloat) -> [String: Any] {
        [
            kCGWindowOwnerName as String: owner,
            kCGWindowLayer as String: layer,
            kCGWindowBounds as String: CGRect(x: x, y: y, width: width, height: height).dictionaryRepresentation,
        ]
    }

    func testFindsTheLargestNormalLayerSettingsWindow() {
        let windows = [
            window(owner: "Safari", width: 1400, height: 900),
            window(owner: "System Settings", layer: 25, width: 2000, height: 2000), // a menu or popover
            window(owner: "System Settings", width: 250, height: 180),              // too small (a sheet's shadow, a tooltip)
            window(owner: "System Settings", x: 100, y: 50, width: 715, height: 600),
            window(owner: "System Settings", x: 900, y: 50, width: 400, height: 300),
        ]
        XCTAssertEqual(SettingsWindowGeometry.settingsWindowFrame(in: windows), CGRect(x: 100, y: 50, width: 715, height: 600))
    }

    func testAcceptsTheOldSystemPreferencesOwnerName() {
        let windows = [window(owner: "System Preferences", width: 668, height: 500)]
        XCTAssertEqual(SettingsWindowGeometry.settingsWindowFrame(in: windows), CGRect(x: 0, y: 0, width: 668, height: 500))
    }

    func testNoSettingsWindow() {
        XCTAssertNil(SettingsWindowGeometry.settingsWindowFrame(in: []))
        XCTAssertNil(SettingsWindowGeometry.settingsWindowFrame(in: [window(owner: "Finder", width: 800, height: 600)]))
        // Malformed entries are skipped, not crashed on.
        XCTAssertNil(SettingsWindowGeometry.settingsWindowFrame(in: [[kCGWindowOwnerName as String: "System Settings"]]))
    }

    // MARK: - Coordinate conversion

    func testQuartzToAppKitOnThePrimaryScreen() {
        // Quartz: origin at the primary screen's top-left, y down.
        let quartz = CGRect(x: 100, y: 50, width: 700, height: 600)
        let appKit = SettingsWindowGeometry.appKitFrame(fromQuartz: quartz, primaryScreenHeight: 1080)
        XCTAssertEqual(appKit, CGRect(x: 100, y: 1080 - 50 - 600, width: 700, height: 600))
    }

    func testQuartzToAppKitOnASecondaryScreenAbove() {
        // A display stacked above the primary has negative Quartz y.
        let quartz = CGRect(x: 200, y: -1200, width: 700, height: 600)
        let appKit = SettingsWindowGeometry.appKitFrame(fromQuartz: quartz, primaryScreenHeight: 1080)
        XCTAssertEqual(appKit.origin.y, 1080 + 1200 - 600)
        XCTAssertEqual(appKit.size, quartz.size)
    }

    func testPicksTheScreenShowingMostOfTheWindow() {
        let screens = [
            CGRect(x: 0, y: 0, width: 1920, height: 1080),
            CGRect(x: 1920, y: 0, width: 2560, height: 1440),
        ]
        // Straddles both, mostly on the right one.
        let settings = CGRect(x: 1800, y: 200, width: 700, height: 600)
        XCTAssertEqual(SettingsWindowGeometry.screenIndex(for: settings, screenFrames: screens), 1)
        XCTAssertEqual(SettingsWindowGeometry.screenIndex(for: CGRect(x: 100, y: 100, width: 700, height: 600), screenFrames: screens), 0)
        XCTAssertNil(SettingsWindowGeometry.screenIndex(for: CGRect(x: -5000, y: 0, width: 10, height: 10), screenFrames: screens))
    }

    func testGuideDocksUnderTheWindowWhenThereIsRoom() {
        let visible = CGRect(x: 0, y: 0, width: 1920, height: 1055)
        let settings = CGRect(x: 600, y: 400, width: 715, height: 600)
        let size = CGSize(width: 440, height: 132)
        let origin = SettingsWindowGeometry.guideOrigin(settings: settings, guideSize: size, visible: visible)
        XCTAssertEqual(origin.x, settings.midX - 220)
        XCTAssertEqual(origin.y, settings.minY - SettingsWindowGeometry.gap - size.height)
    }

    func testGuideTucksInsideTheBottomEdgeWithNoRoomBelow() {
        let visible = CGRect(x: 0, y: 0, width: 1920, height: 1055)
        let settings = CGRect(x: 600, y: 20, width: 715, height: 900)
        let size = CGSize(width: 440, height: 132)
        let origin = SettingsWindowGeometry.guideOrigin(settings: settings, guideSize: size, visible: visible)
        XCTAssertEqual(origin.y, settings.minY + 16)
    }

    func testGuideStaysOnScreenOnASecondaryDisplay() {
        // Right-hand display; window hugging its right edge.
        let visible = CGRect(x: 1920, y: 0, width: 2560, height: 1415)
        let settings = CGRect(x: 4200, y: 600, width: 715, height: 600)
        let size = CGSize(width: 440, height: 132)
        let origin = SettingsWindowGeometry.guideOrigin(settings: settings, guideSize: size, visible: visible)
        XCTAssertEqual(origin.x, visible.maxX - size.width - SettingsWindowGeometry.margin)
        XCTAssertGreaterThanOrEqual(origin.x, visible.minX)
    }

    // MARK: - State machine

    private let frame = CGRect(x: 100, y: 100, width: 715, height: 600)

    func testOpeningThenGuidingThenGranted() {
        var machine = PermissionGuideMachine()
        XCTAssertFalse(machine.isActive)
        machine.start(now: 0)
        XCTAssertEqual(machine.phase, .opening(since: 0))
        XCTAssertEqual(machine.tick(now: 0.1, granted: false, settingsFrame: nil), .none)
        XCTAssertEqual(machine.tick(now: 0.2, granted: false, settingsFrame: frame), .dock(frame))
        XCTAssertEqual(machine.phase, .guiding(missingSince: nil))
        // Follows a moved window.
        let moved = frame.offsetBy(dx: 300, dy: 0)
        XCTAssertEqual(machine.tick(now: 0.3, granted: false, settingsFrame: moved), .dock(moved))
        XCTAssertEqual(machine.tick(now: 0.4, granted: true, settingsFrame: moved), .finish(.granted))
        XCTAssertEqual(machine.phase, .finished(.granted))
        XCTAssertFalse(machine.isActive)
        // Finished machines stay finished.
        XCTAssertEqual(machine.tick(now: 0.5, granted: false, settingsFrame: frame), .none)
    }

    func testGrantedWhileStillOpening() {
        var machine = PermissionGuideMachine()
        machine.start(now: 0)
        XCTAssertEqual(machine.tick(now: 0.1, granted: true, settingsFrame: nil), .finish(.granted))
    }

    func testClosingSystemSettingsClosesTheGuideAfterTheGrace() {
        var machine = PermissionGuideMachine()
        machine.start(now: 0)
        _ = machine.tick(now: 0.1, granted: false, settingsFrame: frame)
        XCTAssertEqual(machine.tick(now: 1.0, granted: false, settingsFrame: nil), .none)
        XCTAssertEqual(machine.tick(now: 1.2, granted: false, settingsFrame: nil), .none)
        XCTAssertEqual(machine.tick(now: 1.0 + PermissionGuideMachine.closeGrace + 0.01, granted: false, settingsFrame: nil), .finish(.settingsClosed))
    }

    func testAWindowThatBlinksDuringAPaneSwitchKeepsTheGuide() {
        var machine = PermissionGuideMachine()
        machine.start(now: 0)
        _ = machine.tick(now: 0.1, granted: false, settingsFrame: frame)
        XCTAssertEqual(machine.tick(now: 1.0, granted: false, settingsFrame: nil), .none)
        XCTAssertEqual(machine.tick(now: 1.1, granted: false, settingsFrame: frame), .dock(frame))
        // The missing clock restarts, so a later gap gets the full grace.
        XCTAssertEqual(machine.tick(now: 2.0, granted: false, settingsFrame: nil), .none)
        XCTAssertEqual(machine.tick(now: 2.2, granted: false, settingsFrame: nil), .none)
    }

    func testSystemSettingsThatNeverOpensTimesOut() {
        var machine = PermissionGuideMachine()
        machine.start(now: 10)
        XCTAssertEqual(machine.tick(now: 10 + PermissionGuideMachine.openingTimeout - 0.1, granted: false, settingsFrame: nil), .none)
        XCTAssertEqual(machine.tick(now: 10 + PermissionGuideMachine.openingTimeout, granted: false, settingsFrame: nil), .finish(.timedOut))
    }

    func testCancel() {
        var machine = PermissionGuideMachine()
        machine.cancel()
        XCTAssertEqual(machine.phase, .idle, "Cancelling an idle machine does nothing")
        machine.start(now: 0)
        machine.cancel()
        XCTAssertEqual(machine.phase, .finished(.cancelled))
    }

    // MARK: - Flight curve

    func testFlightArcStartsAndEndsOnItsPointsAndBowsUp() {
        let start = CGPoint(x: 100, y: 100)
        let end = CGPoint(x: 900, y: 300)
        XCTAssertEqual(PermissionGuideFlight.arcPoint(from: start, to: end, progress: 0), start)
        XCTAssertEqual(PermissionGuideFlight.arcPoint(from: start, to: end, progress: 1), end)
        let middle = PermissionGuideFlight.arcPoint(from: start, to: end, progress: 0.5)
        XCTAssertGreaterThan(middle.y, max(start.y, end.y), "the tile arcs above both ends")
        XCTAssertEqual(PermissionGuideFlight.easeInOutCubic(0), 0)
        XCTAssertEqual(PermissionGuideFlight.easeInOutCubic(1), 1)
        XCTAssertEqual(PermissionGuideFlight.easeInOutCubic(0.5), 0.5, accuracy: 0.0001)
    }

    // MARK: - Opener

    @MainActor
    func testWarmOpenSendsTheURLOnce() {
        var opened: [URL] = []
        let opener = SystemSettingsOpener(isRunning: { true }, hasWindow: { true }, openURL: { opened.append($0) })
        opener.open(GuidedPermission.accessibility.settingsURL)
        XCTAssertEqual(opened, [GuidedPermission.accessibility.settingsURL])
    }

    @MainActor
    func testANewerRequestMakesOlderRetriesStandDown() {
        var opened: [URL] = []
        let opener = SystemSettingsOpener(isRunning: { false }, hasWindow: { false }, openURL: { opened.append($0) })
        let first = GuidedPermission.accessibility.settingsURL
        let second = GuidedPermission.microphone.settingsURL
        opener.open(first)
        let firstRequest = opener.generation
        opener.open(second)
        opener.resend(first, request: firstRequest)
        XCTAssertEqual(opened, [first, second], "a stale retry must not reopen the old pane")
        opener.resend(second, request: opener.generation)
        XCTAssertEqual(opened, [first, second, second])
        opener.invalidate()
        opener.resend(second, request: opener.generation - 1)
        XCTAssertEqual(opened.count, 3)
    }

    @MainActor
    func testColdLaunchResendsOnceTheWindowIsUp() {
        var opened: [URL] = []
        var hasWindow = false
        let opener = SystemSettingsOpener(isRunning: { false }, hasWindow: { hasWindow }, openURL: { opened.append($0) })
        let url = GuidedPermission.accessibility.settingsURL
        opener.open(url)
        XCTAssertEqual(opened.count, 1)
        hasWindow = true
        let resent = expectation(description: "re-sent after the cold launch settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { resent.fulfill() }
        wait(for: [resent], timeout: 3)
        XCTAssertEqual(opened, [url, url, url])
    }

    // MARK: - Controller

    @MainActor
    func testAlreadyGrantedGetsNoGuideJustTheCheck() {
        var opened: [URL] = []
        let opener = SystemSettingsOpener(isRunning: { true }, hasWindow: { true }, openURL: { opened.append($0) })
        let controller = PermissionGuideController(opener: opener, isGranted: { _ in true })
        var outcomes: [PermissionGuideOutcome] = []
        controller.show(.accessibility) { outcomes.append($0) }
        XCTAssertEqual(outcomes, [.granted])
        XCTAssertTrue(opened.isEmpty, "a granted permission opens nothing")
        XCTAssertNil(controller.activePermission)
    }

    @MainActor
    func testCancelReportsOnceAndClears() {
        var opened: [URL] = []
        let opener = SystemSettingsOpener(isRunning: { true }, hasWindow: { true }, openURL: { opened.append($0) })
        let controller = PermissionGuideController(opener: opener, isGranted: { _ in false })
        var outcomes: [PermissionGuideOutcome] = []
        controller.show(.microphone) { outcomes.append($0) }
        XCTAssertEqual(controller.activePermission, .microphone)
        XCTAssertEqual(opened, [GuidedPermission.microphone.settingsURL])
        controller.cancel()
        controller.cancel()
        XCTAssertEqual(outcomes, [.cancelled])
        XCTAssertNil(controller.activePermission)
    }

    @MainActor
    func testShowingAgainReplacesTheOpenGuide() {
        let opener = SystemSettingsOpener(isRunning: { true }, hasWindow: { true }, openURL: { _ in })
        let controller = PermissionGuideController(opener: opener, isGranted: { _ in false })
        var first: [PermissionGuideOutcome] = []
        var second: [PermissionGuideOutcome] = []
        controller.show(.microphone) { first.append($0) }
        controller.show(.accessibility) { second.append($0) }
        XCTAssertEqual(first, [.cancelled])
        XCTAssertEqual(controller.activePermission, .accessibility)
        controller.cancel()
        XCTAssertEqual(second, [.cancelled])
    }
}
