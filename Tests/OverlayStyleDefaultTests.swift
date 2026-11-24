import XCTest
@testable import Whispur

final class OverlayStyleDefaultTests: XCTestCase {
    func testNewInstallsGetCompactWhichSitsAtTheBottom() {
        XCTAssertEqual(OverlayStyle.newInstallDefault, .compact)
    }

    func testPinDecisionCoversEveryInstall() {
        // A new install writes the new default straight away.
        XCTAssertEqual(AppState.overlayStyleToPin(stored: nil, isExistingInstall: false), .compact)
        // An existing install that never picked one keeps the old default.
        XCTAssertEqual(AppState.overlayStyleToPin(stored: nil, isExistingInstall: true), .standard)
        // An explicit choice is never touched.
        XCTAssertNil(AppState.overlayStyleToPin(stored: OverlayStyle.compact.rawValue, isExistingInstall: true))
        XCTAssertNil(AppState.overlayStyleToPin(stored: OverlayStyle.standard.rawValue, isExistingInstall: true))
        XCTAssertNil(AppState.overlayStyleToPin(stored: OverlayStyle.standard.rawValue, isExistingInstall: false))
    }

    func testPinningWritesOnceAndSurvivesOnboardingFinishingLater() throws {
        let suite = "whispur.tests.overlay-style.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        // First launch of a new install.
        AppState.pinOverlayStyleIfNeeded(defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: AppState.overlayStyleKey), "compact")
        // Onboarding finishes; the next launch must not turn it into an old install.
        defaults.set(true, forKey: "whispur.onboarding.completed")
        AppState.pinOverlayStyleIfNeeded(defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: AppState.overlayStyleKey), "compact")
    }

    func testExistingInstallsWithoutAChoiceKeepStandard() throws {
        for key in ["whispur.onboarding.completed", "holdShortcut", "toggleShortcut", "shortcutStyle"] {
            let suite = "whispur.tests.overlay-style.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            if key == "whispur.onboarding.completed" { defaults.set(true, forKey: key) } else { defaults.set("off", forKey: key) }
            AppState.pinOverlayStyleIfNeeded(defaults: defaults)
            XCTAssertEqual(defaults.string(forKey: AppState.overlayStyleKey), "standard", key)
        }
    }

    func testAnExplicitChoiceOnAnExistingInstallIsKept() throws {
        for style in OverlayStyle.allCases {
            let suite = "whispur.tests.overlay-style.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set(true, forKey: "whispur.onboarding.completed")
            defaults.set(style.rawValue, forKey: AppState.overlayStyleKey)
            AppState.pinOverlayStyleIfNeeded(defaults: defaults)
            XCTAssertEqual(defaults.string(forKey: AppState.overlayStyleKey), style.rawValue)
        }
    }
}
