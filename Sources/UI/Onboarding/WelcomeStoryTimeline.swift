import Foundation

/// The welcome screen's before-and-after, told five times: someone sends a
/// message, and the same reply gets written twice. By hand it hesitates,
/// slips, backspaces and takes six to seven seconds; by voice it arrives
/// whole in a second and a half. Each example plays, holds its finished
/// scene, then the next one starts; after the last, the first comes back.
///
/// Pure data: each example is an ordered list of timed events and the frame
/// they add up to at any moment, and `position(at:)` maps time on the loop
/// to an example and a time within it, so the view only draws frames and
/// tests can check the story without rendering it.
enum WelcomeStoryTimeline {
    // MARK: Events

    enum Event: Equatable {
        /// The hand-typed draft now reads `text`.
        case handTyped(String)
        /// The hand-typed reply is finished.
        case handDone
        /// Recording starts in the voice composer.
        case voiceListening
        /// Recording stops and the words start to land.
        case voiceLanding
        /// The spoken reply is in.
        case voiceDone
    }

    struct TimedEvent: Equatable {
        let at: TimeInterval
        let event: Event
    }

    /// One step of the hand-typing script.
    enum Op {
        case type(String)
        case back(Int)
        case pause(TimeInterval)
    }

    // MARK: Shared timing

    /// A beat before either side starts, so the scene reads first.
    static let lead: TimeInterval = 0.4
    /// Voice: talking, then the cleaned-up sentence settling in.
    static let voiceListenDuration: TimeInterval = 1.05
    static let voiceLandDuration: TimeInterval = 0.45
    static var voiceDuration: TimeInterval { voiceListenDuration + voiceLandDuration }
    /// How long a finished scene holds before the next example starts.
    static let hold: TimeInterval = 2.5

    private static let typePace: TimeInterval = 0.068
    private static let backPace: TimeInterval = 0.07

    /// Small, repeatable unevenness so the typing doesn't tick like a metronome.
    private static func wobble(_ n: Int) -> Double {
        let x = abs((sin(Double(n) * 12.9898) * 43_758.5453).truncatingRemainder(dividingBy: 1))
        return 0.7 + 0.6 * x
    }

    // MARK: Examples

    /// One message and its reply. The hand script types the reply with one
    /// natural slip and its fix; it must end on exactly `reply`.
    struct Example {
        /// What the other person asked.
        let question: String
        /// The reply, as it ends up in both composers.
        let reply: String
        /// The misspelling the hand types, then corrects.
        let typo: String
        let script: [Op]

        /// Everything that happens, in time order.
        let events: [TimedEvent]
        /// When the hand-typed reply is finished.
        let handEnd: TimeInterval

        init(question: String, reply: String, typo: String, script: [Op]) {
            self.question = question
            self.reply = reply
            self.typo = typo
            self.script = script
            let hand = WelcomeStoryTimeline.handTrack(script)
            handEnd = hand.end
            events = (hand.events + WelcomeStoryTimeline.voiceEvents).sorted { $0.at < $1.at }
        }

        var handDuration: TimeInterval { handEnd - WelcomeStoryTimeline.lead }
        /// When the whole scene has played out.
        var end: TimeInterval { max(handEnd, WelcomeStoryTimeline.lead + WelcomeStoryTimeline.voiceDuration) }
        /// This example's slot on the loop: the scene, then the hold.
        var slot: TimeInterval { end + WelcomeStoryTimeline.hold }

        /// The scene at `time` seconds in. Before zero it's the empty
        /// opening; past `end` it's the finished pair.
        func frame(at time: TimeInterval) -> Frame {
            var frame = Frame(reply: reply)
            for timed in events where timed.at <= time {
                switch timed.event {
                case let .handTyped(text): frame.handText = text
                case .handDone: frame.handDone = true
                case .voiceListening: frame.voicePhase = .listening
                case .voiceLanding: frame.voicePhase = .landing(0)
                case .voiceDone: frame.voicePhase = .done
                }
            }
            let lead = WelcomeStoryTimeline.lead
            if case .landing = frame.voicePhase {
                let start = lead + WelcomeStoryTimeline.voiceListenDuration
                frame.voicePhase = .landing(min(max((time - start) / WelcomeStoryTimeline.voiceLandDuration, 0), 1))
            }
            frame.handElapsed = min(max(time - lead, 0), handDuration)
            frame.voiceElapsed = min(max(time - lead, 0), WelcomeStoryTimeline.voiceDuration)
            return frame
        }

        /// The finished scene.
        var finalFrame: Frame { frame(at: end) }
    }

    /// The five examples, in the order they play.
    static let examples: [Example] = [
        Example(
            question: "Hi! Any chance you could look at our leaking tap this week?",
            reply: "Sure, I can come by Thursday at 9 and bring a new washer.",
            typo: "Thrusday",
            script: [
                .type("Sure, I can come by "),
                .pause(0.42),
                .type("Thrusday"),
                .pause(0.38),
                .back(6),
                .type("ursday at 9"),
                .pause(0.5),
                .type(" and bring a new washer."),
            ]
        ),
        Example(
            question: "Can you send the deck before the 3pm call?",
            reply: "Yep, sending it now. I added the pricing slide you asked for.",
            typo: "pricnig",
            script: [
                .type("Yep, sending it now. "),
                .pause(0.45),
                .type("I added the pricnig"),
                .pause(0.38),
                .back(3),
                .type("ing slide"),
                .pause(0.4),
                .type(" you asked for."),
            ]
        ),
        Example(
            question: "Could we push our meeting to next week?",
            reply: "Of course. Does Tuesday at 2 work? I'll send a new invite.",
            typo: "Tuesdya",
            script: [
                .type("Of course. "),
                .pause(0.4),
                .type("Does Tuesdya"),
                .pause(0.38),
                .back(2),
                .type("ay at 2 work?"),
                .pause(0.5),
                .type(" I'll send"),
                .pause(0.3),
                .type(" a new invite."),
            ]
        ),
        Example(
            question: "Dinner tonight? We're thinking Thai.",
            reply: "I'm in! Book for 7 and I'll meet you there after work.",
            typo: "aftre",
            script: [
                .type("I'm in! "),
                .pause(0.42),
                .type("Book for 7"),
                .pause(0.5),
                .type(" and I'll meet you"),
                .pause(0.35),
                .type(" there aftre"),
                .pause(0.38),
                .back(2),
                .type("er work."),
            ]
        ),
        Example(
            question: "Did the deploy fix the login bug?",
            reply: "Yes, it's live. Logins work again and I added a test for it.",
            typo: "tset",
            script: [
                .type("Yes, it's live. "),
                .pause(0.45),
                .type("Logins work again"),
                .pause(0.4),
                .type(" and I added a tset"),
                .pause(0.38),
                .back(3),
                .type("est for it."),
            ]
        ),
    ]

    /// One pass through every example, holds included.
    static var cycleDuration: TimeInterval { examples.reduce(0) { $0 + $1.slot } }

    /// Which example shows `elapsed` seconds after the loop started, and how
    /// far into it. Examples differ in length, so this walks the slots.
    static func position(at elapsed: TimeInterval) -> (example: Int, time: TimeInterval) {
        guard elapsed > 0 else { return (0, 0) }
        var remaining = elapsed.truncatingRemainder(dividingBy: cycleDuration)
        for (index, example) in examples.enumerated() {
            if remaining < example.slot { return (index, remaining) }
            remaining -= example.slot
        }
        return (0, 0)
    }

    // MARK: Building an example

    private static func handTrack(_ script: [Op]) -> (events: [TimedEvent], end: TimeInterval) {
        var out: [TimedEvent] = []
        var text = ""
        var t = lead
        var n = 0
        for op in script {
            switch op {
            case let .type(chars):
                for c in chars {
                    n += 1
                    t += typePace * wobble(n) + (c == " " ? 0.03 : 0)
                    text.append(c)
                    out.append(TimedEvent(at: t, event: .handTyped(text)))
                }
            case let .back(count):
                for _ in 0..<count {
                    t += backPace
                    text.removeLast()
                    out.append(TimedEvent(at: t, event: .handTyped(text)))
                }
            case let .pause(seconds):
                t += seconds
            }
        }
        t += 0.12
        out.append(TimedEvent(at: t, event: .handDone))
        return (out, t)
    }

    private static let voiceEvents: [TimedEvent] = [
        TimedEvent(at: lead, event: .voiceListening),
        TimedEvent(at: lead + voiceListenDuration, event: .voiceLanding),
        TimedEvent(at: lead + voiceListenDuration + voiceLandDuration, event: .voiceDone),
    ]

    // MARK: Frames

    enum VoicePhase: Equatable {
        case waiting
        case listening
        /// 0...1 through the words settling in.
        case landing(Double)
        case done
    }

    struct Frame: Equatable {
        /// The example's reply, which the voice side shows once it lands.
        var reply: String
        var handText = ""
        var handDone = false
        /// Seconds on the hand-typed clock.
        var handElapsed: TimeInterval = 0
        var voicePhase: VoicePhase = .waiting
        /// Seconds on the voice clock.
        var voiceElapsed: TimeInterval = 0

        var voiceText: String {
            switch voicePhase {
            case .waiting, .listening: return ""
            case .landing, .done: return reply
            }
        }
    }

    /// "6.6 s" on the clocks.
    static func clock(_ seconds: TimeInterval) -> String {
        String(format: "%.1f s", seconds)
    }
}
