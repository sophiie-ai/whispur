import XCTest
@testable import Whispur

final class AppInstallLocationTests: XCTestCase {
    private let home = "/Users/ada"

    private func classify(
        _ path: String,
        translocated: Bool = false,
        readOnly: Bool = false
    ) -> AppInstallLocation {
        AppInstallLocation.classify(
            bundlePath: path,
            homeDirectory: home,
            isTranslocated: translocated,
            isOnReadOnlyVolume: readOnly
        )
    }

    // MARK: - Allow side: no prompt

    func testApplicationsFoldersNeverPrompt() {
        XCTAssertEqual(classify("/Applications/Whispur.app"), .applicationsFolder)
        XCTAssertEqual(classify("/Applications/Utilities/Whispur.app"), .applicationsFolder)
        XCTAssertEqual(classify("/Users/ada/Applications/Whispur.app"), .applicationsFolder)
        XCTAssertEqual(classify("/Users/ada/Applications/Tools/Whispur.app"), .applicationsFolder)
        XCTAssertFalse(classify("/Applications/Whispur.app").shouldOfferMove)
    }

    func testDevelopmentBuildsNeverPrompt() {
        let paths = [
            "/Users/ada/Library/Developer/Xcode/DerivedData/Whispur-abc/Build/Products/Debug/Whispur.app",
            "/Users/ada/code/whispur/build/Build/Products/Release/Whispur.app",
            "/Users/ada/code/whispur/build/test/Build/Products/Debug/Whispur.app",
            "/Users/ada/code/whispur/.build/debug/Whispur",
        ]
        for path in paths {
            XCTAssertEqual(classify(path), .developmentBuild, path)
            XCTAssertFalse(classify(path).shouldOfferMove, path)
        }
    }

    func testANonBundleExecutableIsADevelopmentBuild() {
        XCTAssertEqual(classify("/Users/ada/Downloads/whispur"), .developmentBuild)
    }

    func testOtherUsersApplicationsFolderIsNotOurs() {
        XCTAssertEqual(classify("/Users/bob/Applications/Whispur.app"), .elsewhere)
    }

    // MARK: - Block side: prompt

    func testDownloadsAndDesktopPrompt() {
        XCTAssertEqual(classify("/Users/ada/Downloads/Whispur.app"), .elsewhere)
        XCTAssertEqual(classify("/Users/ada/Desktop/Whispur.app"), .elsewhere)
        XCTAssertTrue(classify("/Users/ada/Downloads/Whispur.app").shouldOfferMove)
    }

    func testLookalikeApplicationsPathPrompts() {
        XCTAssertEqual(classify("/ApplicationsOld/Whispur.app"), .elsewhere)
        XCTAssertEqual(classify("/Users/ada/Downloads/Applications.zip folder/Whispur.app"), .elsewhere)
    }

    func testMountedDiskImagePromptsWithItsVolume() {
        let location = classify("/Volumes/Whispur/Whispur.app", readOnly: true)
        XCTAssertEqual(location, .diskImage(volumePath: "/Volumes/Whispur"))
        XCTAssertTrue(location.shouldOfferMove)
    }

    func testWritableExternalVolumeIsNotADiskImage() {
        XCTAssertEqual(classify("/Volumes/USB Stick/Whispur.app", readOnly: false), .elsewhere)
    }

    func testTranslocatedPathPrompts() {
        let path = "/private/var/folders/xy/abc123/T/AppTranslocation/1B2C3D4E/d/Whispur.app"
        XCTAssertEqual(classify(path), .translocated)
        XCTAssertTrue(classify(path).shouldOfferMove)
        XCTAssertTrue(AppInstallLocation.isTranslocationPath(path))
    }

    func testSystemReportedTranslocationWinsOverPathShape() {
        XCTAssertEqual(classify("/Applications/Whispur.app", translocated: true), .translocated)
    }

    // MARK: - Opt-outs

    @MainActor
    func testOptOuts() {
        let suite = "AppInstallLocationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertFalse(ApplicationsFolderMover.isOptedOut(defaults: defaults, environment: [:]))
        XCTAssertTrue(ApplicationsFolderMover.isOptedOut(
            defaults: defaults,
            environment: [ApplicationsFolderMover.optOutEnvironmentKey: "1"]
        ))
        XCTAssertFalse(ApplicationsFolderMover.isOptedOut(
            defaults: defaults,
            environment: [ApplicationsFolderMover.optOutEnvironmentKey: "0"]
        ))
        XCTAssertTrue(ApplicationsFolderMover.isOptedOut(
            defaults: defaults,
            environment: ["XCTestConfigurationFilePath": "/tmp/x"]
        ))

        defaults.set(true, forKey: ApplicationsFolderMover.optOutDefaultsKey)
        XCTAssertTrue(ApplicationsFolderMover.isOptedOut(defaults: defaults, environment: [:]))
    }
}
