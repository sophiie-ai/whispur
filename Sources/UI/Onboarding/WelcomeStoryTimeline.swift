import Foundation

/// The welcome screen's before-and-after, told five times: someone sends a
/// message, and the same reply gets written twice. By hand it hesitates,
/// slips and backspaces; by voice it arrives whole and then sits done while
/// the hand keeps typing. Everything plays in real time, with durations
/// derived from the reply and the script. Each example plays, holds its
/// finished scene, then the next one starts; after the last, the first
/// comes back.
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

    // MARK: Timing

    /// A confident typist at about 65 wpm, on average (the wobble averages 1).
    static let secondsPerCharacter: TimeInterval = 0.18
    /// A backspace is a quick repeated key.
    static let secondsPerBackspace: TimeInterval = 0.08
    /// The beat between the last letter and hitting send.
    static let finishBeat: TimeInterval = 0.2
    /// Speaking at a fast conversational pace, about 180 wpm.
    static let wordsPerSecond: Double = 3
    /// Transcription and cleanup after the speaker stops, before text lands:
    /// a measured dictation took 106 ms in Parakeet plus 393 ms of LLM
    /// cleanup, and Parakeet alone is quicker.
    static let landDuration: TimeInterval = 0.4
    /// A beat before either side starts, so the scene reads first.
    static let lead: TimeInterval = 0.4
    /// How long a finished scene holds before the next example starts.
    static let hold: TimeInterval = 2.5

    /// Small, repeatable unevenness so the typing doesn't tick like a metronome.
    private static func wobble(_ n: Int) -> Double {
        let x = abs((sin(Double(n) * 12.9898) * 43_758.5453).truncatingRemainder(dividingBy: 1))
        return 0.7 + 0.6 * x
    }

    // MARK: Examples

    /// One message and its reply. The hand script types the reply with one
    /// natural slip and its fix (pauses in seconds); it must end on
    /// exactly `reply`. Every duration is derived from the text and script.
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
        /// Seconds to type the reply by hand, slip and pauses included.
        let handDuration: TimeInterval

        init(question: String, reply: String, typo: String, script: [Op]) {
            self.question = question
            self.reply = reply
            self.typo = typo
            self.script = script
            let hand = WelcomeStoryTimeline.handTrack(script)
            handDuration = hand.duration
            let listen = WelcomeStoryTimeline.listenDuration(for: reply)
            let lead = WelcomeStoryTimeline.lead
            let voiceEvents = [
                TimedEvent(at: lead, event: .voiceListening),
                TimedEvent(at: lead + listen, event: .voiceLanding),
                TimedEvent(at: lead + listen + WelcomeStoryTimeline.landDuration, event: .voiceDone),
            ]
            events = (hand.events + voiceEvents).sorted { $0.at < $1.at }
        }

        /// Seconds spent speaking the reply's words.
        var listenDuration: TimeInterval { WelcomeStoryTimeline.listenDuration(for: reply) }
        /// Seconds to say it: the words at speaking pace, then landing.
        var voiceDuration: TimeInterval { listenDuration + WelcomeStoryTimeline.landDuration }

        /// When the whole scene has played out.
        var end: TimeInterval { WelcomeStoryTimeline.lead + max(handDuration, voiceDuration) }
        /// This example's slot on the loop: the scene, then the hold.
        var slot: TimeInterval { end + WelcomeStoryTimeline.hold }

        /// The scene at `time` seconds in. Before zero it's the empty
        /// opening; past `end` it's the finished pair. The clocks show the
        /// seconds since each side started, stopping when it's done.
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
                let start = lead + listenDuration
                frame.voicePhase = .landing(min(max((time - start) / WelcomeStoryTimeline.landDuration, 0), 1))
            }
            let elapsed = max(time - lead, 0)
            frame.handElapsed = min(elapsed, handDuration)
            frame.voiceElapsed = min(elapsed, voiceDuration)
            return frame
        }

        /// The finished scene.
        var finalFrame: Frame { frame(at: end) }
    }

    /// Seconds to speak `reply`'s words.
    static func listenDuration(for reply: String) -> TimeInterval {
        Double(reply.split(whereSeparator: \.isWhitespace).count) / wordsPerSecond
    }

    /// The five examples, in the order they play.
    static let examples: [Example] = [
        Example(
            question: "Hi! Any chance you could look at our leaking tap this week?",
            reply: "Sure, I can come by Thursday at 9 and bring a new washer.",
            typo: "Thrusday",
            script: [
                .type("Sure, I can come by "),
                .pause(0.35),
                .type("Thrusday"),
                .pause(0.35),
                .back(6),
                .type("ursday at 9"),
                .pause(0.45),
                .type(" and bring a new washer."),
            ]
        ),
        Example(
            question: "Can you send the deck before the 3pm call?",
            reply: "Sending it now, pricing slide included.",
            typo: "pricnig",
            script: [
                .type("Sending it now, "),
                .pause(0.35),
                .type("pricnig"),
                .pause(0.35),
                .back(3),
                .type("ing slide"),
                .pause(0.3),
                .type(" included."),
            ]
        ),
        Example(
            question: "Could we push our meeting to next week?",
            reply: "Of course. Does Tuesday at 2 work? I'll send a new invite.",
            typo: "Tuesdya",
            script: [
                .type("Of course. "),
                .pause(0.35),
                .type("Does Tuesdya"),
                .pause(0.35),
                .back(2),
                .type("ay at 2 work?"),
                .pause(0.45),
                .type(" I'll send"),
                .pause(0.3),
                .type(" a new invite."),
            ]
        ),
        Example(
            question: "Dinner tonight? We're thinking Thai.",
            reply: "I'm in! See you at 7.",
            typo: "Se you",
            script: [
                .type("I'm in! "),
                .pause(0.3),
                .type("Se you"),
                .pause(0.35),
                .back(4),
                .type("e you at 7."),
            ]
        ),
        Example(
            question: "Did the deploy fix the login bug?",
            reply: "Yes, it's live. Logins work again and I added a test for it.",
            typo: "tset",
            script: [
                .type("Yes, it's live. "),
                .pause(0.4),
                .type("Logins work again"),
                .pause(0.35),
                .type(" and I added a tset"),
                .pause(0.35),
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

    /// The hand's keystrokes, and how long it takes.
    private static func handTrack(_ script: [Op]) -> (events: [TimedEvent], duration: TimeInterval) {
        var out: [TimedEvent] = []
        var text = ""
        var elapsed: TimeInterval = 0
        var n = 0
        for op in script {
            switch op {
            case let .type(chars):
                for c in chars {
                    n += 1
                    elapsed += secondsPerCharacter * wobble(n)
                    text.append(c)
                    out.append(TimedEvent(at: lead + elapsed, event: .handTyped(text)))
                }
            case let .back(count):
                for _ in 0..<count {
                    elapsed += secondsPerBackspace
                    text.removeLast()
                    out.append(TimedEvent(at: lead + elapsed, event: .handTyped(text)))
                }
            case let .pause(seconds):
                elapsed += seconds
            }
        }
        elapsed += finishBeat
        out.append(TimedEvent(at: lead + elapsed, event: .handDone))
        return (out, elapsed)
    }

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
