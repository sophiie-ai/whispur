import ServiceManagement
import XCTest
@testable import Whispur

private final class FakeLoginItemService: LoginItemService {
    var status: SMAppService.Status
    var registerCalls = 0
    var unregisterCalls = 0
    var registerError: Error?

    init(status: SMAppService.Status) {
        self.status = status
    }

    func register() throws {
        registerCalls += 1
        if let registerError { throw registerError }
        status = .enabled
    }

    func unregister() throws {
        unregisterCalls += 1
        status = .notRegistered
    }
}

@MainActor
final class LaunchAtLoginTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "ai.sophiie.whispur.tests.launch-at-login"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testFirstLaunchFromApplicationsTurnsItOn() {
        let service = FakeLoginItemService(status: .notRegistered)
        let controller = LaunchAtLogin(service: service, defaults: defaults)
        controller.applyDefaultIfNeeded(location: .applicationsFolder)
        XCTAssertEqual(service.registerCalls, 1)
        XCTAssertTrue(controller.isEnabled)
        XCTAssertTrue(defaults.bool(forKey: LaunchAtLogin.defaultAppliedKey))
    }

    func testTurningItOffSticksAcrossLaunches() {
        let service = FakeLoginItemService(status: .notRegistered)
        let controller = LaunchAtLogin(service: service, defaults: defaults)
        controller.applyDefaultIfNeeded(location: .applicationsFolder)
        controller.setEnabled(false)
        XCTAssertFalse(controller.isEnabled)

        let nextLaunch = LaunchAtLogin(service: service, defaults: defaults)
        nextLaunch.applyDefaultIfNeeded(location: .applicationsFolder)
        XCTAssertEqual(service.registerCalls, 1)
        XCTAssertFalse(nextLaunch.isEnabled)
    }

    func testCopiesOutsideApplicationsWaitForALaterLaunch() {
        let service = FakeLoginItemService(status: .notRegistered)
        let controller = LaunchAtLogin(service: service, defaults: defaults)
        let elsewhere: [AppInstallLocation] = [.developmentBuild, .diskImage(volumePath: "/Volumes/Whispur"), .translocated, .elsewhere]
        for location in elsewhere {
            controller.applyDefaultIfNeeded(location: location)
        }
        XCTAssertEqual(service.registerCalls, 0)
        XCTAssertFalse(defaults.bool(forKey: LaunchAtLogin.defaultAppliedKey))

        controller.applyDefaultIfNeeded(location: .applicationsFolder)
        XCTAssertEqual(service.registerCalls, 1)
    }

    func testExistingSystemStateIsLeftAlone() {
        for status in [SMAppService.Status.enabled, .requiresApproval, .notFound] {
            defaults.removePersistentDomain(forName: suite)
            let service = FakeLoginItemService(status: status)
            LaunchAtLogin(service: service, defaults: defaults).applyDefaultIfNeeded(location: .applicationsFolder)
            XCTAssertEqual(service.registerCalls, 0, "status \(status.rawValue)")
        }
    }

    func testFailedRegistrationIsNotRetried() {
        let service = FakeLoginItemService(status: .notRegistered)
        service.registerError = NSError(domain: "test", code: 1)
        LaunchAtLogin(service: service, defaults: defaults).applyDefaultIfNeeded(location: .applicationsFolder)
        LaunchAtLogin(service: service, defaults: defaults).applyDefaultIfNeeded(location: .applicationsFolder)
        XCTAssertEqual(service.registerCalls, 1)
    }

    func testChoiceMadeOutsideApplicationsSurvivesTheMove() {
        let service = FakeLoginItemService(status: .notRegistered)
        let fromDownloads = LaunchAtLogin(service: service, defaults: defaults)
        fromDownloads.applyDefaultIfNeeded(location: .elsewhere)
        fromDownloads.setEnabled(true)
        fromDownloads.setEnabled(false)

        let fromApplications = LaunchAtLogin(service: service, defaults: defaults)
        fromApplications.applyDefaultIfNeeded(location: .applicationsFolder)
        XCTAssertEqual(service.registerCalls, 1)
        XCTAssertFalse(fromApplications.isEnabled)
    }

    func testPendingApprovalCountsAsOn() {
        let controller = LaunchAtLogin(service: FakeLoginItemService(status: .requiresApproval), defaults: defaults)
        XCTAssertTrue(controller.isEnabled)
        XCTAssertTrue(controller.requiresApproval)
    }
}
