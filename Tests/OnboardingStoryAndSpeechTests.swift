import XCTest
@testable import Whispur

final class OnboardingPlanTests: XCTestCase {
    func testTheLanguageStepSitsRightAfterWelcomeWhenAsked() {
        let plan = OnboardingPlan(asksLanguages: true)
        XCTAssertEqual(plan.steps, [.welcome, .languages, .microphone, .accessibility, .shortcuts, .tryIt, .ready])
        XCTAssertEqual(plan.next(after: .welcome), .languages)
        XCTAssertEqual(plan.next(after: .languages), .microphone)
        XCTAssertEqual(plan.previous(before: .microphone), .languages)
        XCTAssertEqual(plan.number(of: .languages), 2)
        XCTAssertEqual(plan.progress(of: .ready), 1, accuracy: 0.0001)
        let values = plan.steps.map(plan.progress(of:))
        XCTAssertEqual(values, values.sorted())
        // A grant still only advances its own step, within this plan.
        XCTAssertEqual(OnboardingFlow.stepAfterGrant(of: .microphone, showing: .microphone, in: plan), .accessibility)
    }

    func testWithoutTheLanguageStepWelcomeLeadsToTheMicrophone() {
        let plan = OnboardingPlan.standard
        XCTAssertFalse(plan.asksLanguages)
        XCTAssertEqual(plan.next(after: .welcome), .microphone)
        XCTAssertEqual(plan.previous(before: .microphone), .welcome)
        XCTAssertEqual(plan.number(of: .microphone), 2)
        // Opened on a step the plan leaves out, navigation still goes the right way.
        XCTAssertEqual(plan.next(after: .languages), .microphone)
        XCTAssertEqual(plan.previous(before: .languages), .welcome)
    }
}

final class OnboardingSpeechSetupTests: XCTestCase {
    func testOnlyKeylessAppleSiliconParakeetUsersGetTheDownloadFraming() {
        XCTAssertTrue(OnboardingSpeechSetup.usesParakeetDownload(selected: .parakeet, parakeetSupported: true, modelInstalled: false))
        // Cloud keys: the resolver picked something else.
        XCTAssertFalse(OnboardingSpeechSetup.usesParakeetDownload(selected: .openai, parakeetSupported: true, modelInstalled: false))
        XCTAssertFalse(OnboardingSpeechSetup.usesParakeetDownload(selected: .apple, parakeetSupported: true, modelInstalled: false))
        // Intel.
        XCTAssertFalse(OnboardingSpeechSetup.usesParakeetDownload(selected: .apple, parakeetSupported: false, modelInstalled: false))
        XCTAssertFalse(OnboardingSpeechSetup.usesParakeetDownload(selected: .parakeet, parakeetSupported: false, modelInstalled: false))
        // Model already here (a replay, say): nothing to download.
        XCTAssertFalse(OnboardingSpeechSetup.usesParakeetDownload(selected: .parakeet, parakeetSupported: true, modelInstalled: true))
    }

    func testLanguageQuestionGating() {
        XCTAssertTrue(OnboardingSpeechSetup.asksLanguages(usesParakeetDownload: true, languagesStored: true))
        XCTAssertTrue(OnboardingSpeechSetup.asksLanguages(usesParakeetDownload: true, languagesStored: false))
        // Cloud-key and Intel users are only asked when the setting is empty.
        XCTAssertTrue(OnboardingSpeechSetup.asksLanguages(usesParakeetDownload: false, languagesStored: false))
        XCTAssertFalse(OnboardingSpeechSetup.asksLanguages(usesParakeetDownload: false, languagesStored: true))
    }

    func testThePillShowsOnEveryScreenAfterTheLanguagesOnly() {
        let plan = OnboardingPlan(asksLanguages: true)
        let shown = plan.steps.filter { OnboardingSpeechSetup.showsDownloadPill(on: $0, plan: plan, usesParakeetDownload: true) }
        XCTAssertEqual(shown, [.microphone, .accessibility, .shortcuts, .tryIt, .ready])
        // No download framing: no pill anywhere, even with the language step.
        XCTAssertTrue(plan.steps.allSatisfy { !OnboardingSpeechSetup.showsDownloadPill(on: $0, plan: plan, usesParakeetDownload: false) })
        XCTAssertTrue(OnboardingPlan.standard.steps.allSatisfy {
            !OnboardingSpeechSetup.showsDownloadPill(on: $0, plan: .standard, usesParakeetDownload: true)
        })
    }

    func testDefaultLanguageFollowsTheSystemLocale() {
        XCTAssertEqual(OnboardingSpeechSetup.defaultLanguages(systemLocaleIdentifier: "en_US").codes, ["en-US"])
        XCTAssertEqual(OnboardingSpeechSetup.defaultLanguages(systemLocaleIdentifier: "en_GB").codes, ["en-GB"])
        // A region the catalog lacks takes the language's first entry.
        XCTAssertEqual(OnboardingSpeechSetup.defaultLanguages(systemLocaleIdentifier: "en_AU").codes, ["en-US"])
        XCTAssertEqual(OnboardingSpeechSetup.defaultLanguages(systemLocaleIdentifier: "es_AR").codes, ["es-ES"])
        XCTAssertEqual(OnboardingSpeechSetup.defaultLanguages(systemLocaleIdentifier: "pt_PT@calendar=gregorian").codes, ["pt-PT"])
        XCTAssertEqual(OnboardingSpeechSetup.defaultLanguages(systemLocaleIdentifier: "de").codes, ["de-DE"])
        // A language the catalog doesn't have, or nothing: English.
        XCTAssertEqual(OnboardingSpeechSetup.defaultLanguages(systemLocaleIdentifier: "cy_GB").codes, ["en-US"])
        XCTAssertEqual(OnboardingSpeechSetup.defaultLanguages(systemLocaleIdentifier: "").codes, ["en-US"])
    }

    func testPillContentPerDownloadState() {
        let downloading = OnboardingDownloadPill.content(for: .downloading(fraction: 0.4, isPreparing: false))
        XCTAssertEqual(downloading.text, "Speech model 40%")
        XCTAssertEqual(downloading.fraction ?? -1, 0.4, accuracy: 0.0001)
        XCTAssertNil(downloading.action)

        XCTAssertNil(OnboardingDownloadPill.content(for: .downloading(fraction: 1, isPreparing: true)).fraction)
        XCTAssertEqual(OnboardingDownloadPill.content(for: .downloading(fraction: 1.4, isPreparing: false)).text, "Speech model 100%")

        let ready = OnboardingDownloadPill.content(for: .installed(bytesOnDisk: 1))
        XCTAssertEqual(ready.tone, .ready)
        XCTAssertNil(ready.action)

        XCTAssertEqual(OnboardingDownloadPill.content(for: .failed("offline")).action, .retry)
        XCTAssertEqual(OnboardingDownloadPill.content(for: .failed("offline")).tone, .problem)
        XCTAssertEqual(OnboardingDownloadPill.content(for: .waitingForNetwork).action, .downloadNow)
        XCTAssertEqual(OnboardingDownloadPill.content(for: .notDownloaded).action, .downloadNow)
        // The tooltip says dictation already works meanwhile.
        XCTAssertTrue(OnboardingDownloadPill.help.contains("Try it"))
        XCTAssertTrue(OnboardingDownloadPill.help.contains("Apple"))
    }
}

final class WelcomeStoryTimelineTests: XCTestCase {
    typealias Story = WelcomeStoryTimeline

    func testEventsAreInTimeOrder() {
        let times = Story.events.map(\.at)
        XCTAssertEqual(times, times.sorted())
        XCTAssertGreaterThan(times.first ?? 0, 0)
    }

    func testByHandTakesAboutSixAndAHalfSecondsByVoiceOneAndAHalf() {
        XCTAssertEqual(Story.handDuration, 6.5, accuracy: 0.6)
        XCTAssertEqual(Story.voiceDuration, 1.5, accuracy: 0.0001)
        XCTAssertEqual(Story.end, Story.lead + Story.handDuration, accuracy: 0.0001)
    }

    func testBothSidesEndOnTheSameReply() {
        let last = Story.finalFrame
        XCTAssertEqual(last.handText, Story.reply)
        XCTAssertTrue(last.handDone)
        XCTAssertEqual(last.voicePhase, .done)
        XCTAssertEqual(last.voiceText, Story.reply)
        XCTAssertEqual(last.handElapsed, Story.handDuration, accuracy: 0.0001)
        XCTAssertEqual(last.voiceElapsed, Story.voiceDuration, accuracy: 0.0001)
        // Well past the end nothing changes.
        XCTAssertEqual(Story.frame(at: Story.end + 30), last)
    }

    func testTheTypingSlipsAndIsCorrected() {
        let drafts = Story.events.compactMap { timed -> String? in
            if case let .handTyped(text) = timed.event { return text }
            return nil
        }
        XCTAssertTrue(drafts.contains("Sure, I can come by Thrusday"), "the typo is typed")
        let typo = drafts.firstIndex(of: "Sure, I can come by Thrusday")!
        let fixed = drafts.lastIndex(of: "Sure, I can come by Th")!
        XCTAssertGreaterThan(fixed, typo, "then backspaced")
        // Every step is one keystroke: one character more or one fewer.
        for (a, b) in zip(drafts, drafts.dropFirst()) {
            XCTAssertEqual(abs(a.count - b.count), 1)
        }
    }

    func testOpeningAndMidwayFrames() {
        let opening = Story.frame(at: 0)
        XCTAssertEqual(opening.handText, "")
        XCTAssertEqual(opening.voicePhase, .waiting)
        XCTAssertEqual(opening.handElapsed, 0)

        // Mid-recording: voice listening, hand barely started.
        let listening = Story.frame(at: Story.lead + 0.6)
        XCTAssertEqual(listening.voicePhase, .listening)
        XCTAssertEqual(listening.voiceText, "")
        XCTAssertFalse(listening.handText.isEmpty)

        // Landing halfway.
        let landing = Story.frame(at: Story.lead + Story.voiceListenDuration + Story.voiceLandDuration / 2)
        guard case let .landing(progress) = landing.voicePhase else { return XCTFail("expected landing") }
        XCTAssertEqual(progress, 0.5, accuracy: 0.01)

        // Voice done while the hand is still typing.
        let voiceDone = Story.frame(at: Story.lead + Story.voiceDuration + 0.05)
        XCTAssertEqual(voiceDone.voicePhase, .done)
        XCTAssertFalse(voiceDone.handDone)
        XCTAssertNotEqual(voiceDone.handText, Story.reply)
    }

    func testClockFormat() {
        XCTAssertEqual(Story.clock(1.5), "1.5 s")
        XCTAssertEqual(Story.clock(6.54), "6.5 s")
    }
}
