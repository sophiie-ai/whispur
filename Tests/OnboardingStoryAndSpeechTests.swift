import XCTest
@testable import Whispur

final class OnboardingPlanTests: XCTestCase {
    func testTheLanguageStepSitsRightAfterWelcomeWhenAsked() {
        let plan = OnboardingPlan(asksLanguages: true)
        XCTAssertEqual(plan.steps, [.welcome, .languages, .microphone, .accessibility, .tryIt, .ready])
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
        XCTAssertEqual(shown, [.microphone, .accessibility, .tryIt, .ready])
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

    func testThereAreFiveExamplesWithoutBrandNames() {
        XCTAssertEqual(Story.examples.count, 5)
        XCTAssertEqual(Set(Story.examples.map(\.reply)).count, 5)
        for example in Story.examples {
            XCTAssertFalse(example.question.localizedCaseInsensitiveContains("Whispur"), example.question)
            XCTAssertFalse(example.reply.localizedCaseInsensitiveContains("Whispur"), example.reply)
        }
    }

    func testEventsAreInTimeOrder() {
        for example in Story.examples {
            let times = example.events.map(\.at)
            XCTAssertEqual(times, times.sorted(), example.reply)
            XCTAssertGreaterThan(times.first ?? 0, 0, example.reply)
        }
    }

    func testTimesAreBelievableAndDifferBetweenExamples() {
        for example in Story.examples {
            // About 65 wpm typing, about 180 wpm speaking.
            XCTAssertGreaterThanOrEqual(example.handDuration, 4, example.reply)
            XCTAssertLessThanOrEqual(example.handDuration, 16, example.reply)
            XCTAssertGreaterThanOrEqual(example.voiceDuration, 1.5, example.reply)
            XCTAssertLessThanOrEqual(example.voiceDuration, 6, example.reply)
            XCTAssertGreaterThanOrEqual(example.handDuration, 2 * example.voiceDuration, example.reply)
            // Real time: the scene lasts exactly as long as the hand takes.
            XCTAssertEqual(example.end, Story.lead + example.handDuration, accuracy: 0.0001, example.reply)
            XCTAssertEqual(example.slot, example.end + Story.hold, accuracy: 0.0001, example.reply)
        }
        // Derived from each reply, so the numbers differ between examples.
        XCTAssertGreaterThan(Set(Story.examples.map { Story.clock($0.handDuration) }).count, 1)
        XCTAssertGreaterThan(Set(Story.examples.map { Story.clock($0.voiceDuration) }).count, 1)
    }

    func testVoiceTimeComesFromTheWordCount() {
        for example in Story.examples {
            let words = Double(example.reply.split(separator: " ").count)
            XCTAssertEqual(example.voiceDuration, words / Story.wordsPerSecond + Story.landDuration, accuracy: 0.0001)
        }
    }

    func testBothSidesEndOnTheSameReply() {
        for example in Story.examples {
            let last = example.finalFrame
            XCTAssertEqual(last.handText, example.reply)
            XCTAssertTrue(last.handDone)
            XCTAssertEqual(last.voicePhase, .done)
            XCTAssertEqual(last.voiceText, example.reply)
            // The clocks stop on each side's own time.
            XCTAssertEqual(last.handElapsed, example.handDuration, accuracy: 0.0001)
            XCTAssertEqual(last.voiceElapsed, example.voiceDuration, accuracy: 0.0001)
            // Well past the end nothing changes.
            XCTAssertEqual(example.frame(at: example.end + 30), last)
        }
    }

    func testTheTypingSlipsAndIsCorrected() {
        for example in Story.examples {
            let drafts = example.events.compactMap { timed -> String? in
                if case let .handTyped(text) = timed.event { return text }
                return nil
            }
            XCTAssertFalse(example.reply.contains(example.typo), "the typo is not in the reply")
            guard let typo = drafts.firstIndex(where: { $0.hasSuffix(example.typo) }) else {
                return XCTFail("\(example.typo) is never typed")
            }
            // Backspaced to a prefix of the reply, after the typo.
            let fixed = drafts.lastIndex { example.reply.hasPrefix($0) && $0.count < drafts[typo].count }
            XCTAssertNotNil(fixed)
            XCTAssertGreaterThan(fixed ?? 0, typo, "then backspaced")
            // Every step is one keystroke: one character more or one fewer.
            for (a, b) in zip(drafts, drafts.dropFirst()) {
                XCTAssertEqual(abs(a.count - b.count), 1)
            }
        }
    }

    func testOpeningAndMidwayFrames() {
        for example in Story.examples {
            let opening = example.frame(at: 0)
            XCTAssertEqual(opening.handText, "")
            XCTAssertEqual(opening.voicePhase, .waiting)
            XCTAssertEqual(opening.handElapsed, 0)
            // One clock second is one second of playback.
            XCTAssertEqual(example.frame(at: Story.lead + 1).handElapsed, 1, accuracy: 0.0001)
            XCTAssertEqual(example.frame(at: Story.lead + 1).voiceElapsed, 1, accuracy: 0.0001)

            // Mid-recording: voice listening, hand barely started.
            let listening = example.frame(at: Story.lead + 0.6)
            XCTAssertEqual(listening.voicePhase, .listening)
            XCTAssertEqual(listening.voiceText, "")
            XCTAssertFalse(listening.handText.isEmpty)

            // Landing halfway.
            let landing = example.frame(at: Story.lead + example.listenDuration + Story.landDuration / 2)
            guard case let .landing(progress) = landing.voicePhase else { return XCTFail("expected landing") }
            XCTAssertEqual(progress, 0.5, accuracy: 0.01)

            // Voice done while the hand is still typing.
            let voiceDone = example.frame(at: Story.lead + example.voiceDuration + 0.05)
            XCTAssertEqual(voiceDone.voicePhase, .done)
            XCTAssertFalse(voiceDone.handDone)
            XCTAssertNotEqual(voiceDone.handText, example.reply)
        }
    }

    func testTheLoopPlaysEachExampleHoldsThenMovesOnAndWraps() {
        let examples = Story.examples
        XCTAssertEqual(Story.cycleDuration, examples.reduce(0) { $0 + $1.end + Story.hold }, accuracy: 0.0001)
        XCTAssertTrue(Story.position(at: 0) == (0, 0))
        XCTAssertTrue(Story.position(at: -1) == (0, 0))
        // Within the first example.
        XCTAssertEqual(Story.position(at: 1.2).example, 0)
        XCTAssertEqual(Story.position(at: 1.2).time, 1.2, accuracy: 0.0001)
        // The hold shows the finished scene.
        let held = Story.position(at: examples[0].end + Story.hold / 2)
        XCTAssertEqual(held.example, 0)
        XCTAssertEqual(examples[0].frame(at: held.time), examples[0].finalFrame)
        // Each slot hands over to the next example at its start.
        var start: TimeInterval = 0
        for index in examples.indices {
            let position = Story.position(at: start + 0.25)
            XCTAssertEqual(position.example, index)
            XCTAssertEqual(position.time, 0.25, accuracy: 0.0001)
            start += examples[index].slot
        }
        // After the fifth, the first comes back, and keeps doing so.
        XCTAssertEqual(Story.position(at: Story.cycleDuration - 0.01).example, examples.count - 1)
        let wrapped = Story.position(at: Story.cycleDuration + 0.5)
        XCTAssertEqual(wrapped.example, 0)
        XCTAssertEqual(wrapped.time, 0.5, accuracy: 0.0001)
        XCTAssertEqual(Story.position(at: Story.cycleDuration * 7 + 1.25).example, 0)
        XCTAssertEqual(Story.position(at: Story.cycleDuration * 7 + 1.25).time, 1.25, accuracy: 0.0001)
    }

    func testClockFormat() {
        XCTAssertEqual(Story.clock(1.5), "1.5 s")
        XCTAssertEqual(Story.clock(6.54), "6.5 s")
    }
}
