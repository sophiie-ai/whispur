import Foundation

/// The welcome screen's before-and-after: a customer asks about a leaking
/// tap, and the same reply gets written twice. By hand it hesitates, slips,
/// backspaces and takes about six and a half seconds; by voice it arrives
/// whole in a second and a half.
///
/// Pure data: an ordered list of timed events and the frame they add up to
/// at any moment, so the view only draws `frame(at:)` and tests can check
/// the story without rendering it.
enum WelcomeStoryTimeline {
    /// What the customer asked.
    static let question = "Hi! Any chance you could look at our leaking tap this week?"
    /// The reply, as it ends up in both composers.
    static let reply = "Sure, I can come by Thursday at 9 and bring a new washer."

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

    /// Everything that happens, in time order.
    static let events: [TimedEvent] = (handEvents + voiceEvents).sorted { $0.at < $1.at }

    // MARK: Timing

    /// A beat before either side starts, so the scene reads first.
    static let lead: TimeInterval = 0.4
    /// Voice: talking, then the cleaned-up sentence settling in.
    static let voiceListenDuration: TimeInterval = 1.05
    static let voiceLandDuration: TimeInterval = 0.45

    static var handDuration: TimeInterval { handEnd - lead }
    static var voiceDuration: TimeInterval { voiceListenDuration + voiceLandDuration }
    /// When the whole scene has played out.
    static var end: TimeInterval { max(handEnd, lead + voiceDuration) }

    // MARK: Hand typing

    private enum Op {
        case type(String)
        case back(Int)
        case pause(TimeInterval)
    }

    /// Types the start, hesitates, misspells Thursday, notices, fixes it,
    /// hesitates over the time, then finishes.
    private static let handScript: [Op] = [
        .type("Sure, I can come by "),
        .pause(0.42),
        .type("Thrusday"),
        .pause(0.38),
        .back(6),
        .type("ursday at 9"),
        .pause(0.5),
        .type(" and bring a new washer."),
    ]

    private static let typePace: TimeInterval = 0.068
    private static let backPace: TimeInterval = 0.07

    /// Small, repeatable unevenness so the typing doesn't tick like a metronome.
    private static func wobble(_ n: Int) -> Double {
        let x = abs((sin(Double(n) * 12.9898) * 43_758.5453).truncatingRemainder(dividingBy: 1))
        return 0.7 + 0.6 * x
    }

    private static var handEvents: [TimedEvent] { handTrack.events }
    private static var handEnd: TimeInterval { handTrack.end }

    private static let handTrack: (events: [TimedEvent], end: TimeInterval) = {
        var out: [TimedEvent] = []
        var text = ""
        var t = lead
        var n = 0
        for op in handScript {
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
    }()

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
            case .landing, .done: return WelcomeStoryTimeline.reply
            }
        }
    }

    /// The scene at `time` seconds in. Before zero it's the empty opening;
    /// past `end` it's the finished pair.
    static func frame(at time: TimeInterval) -> Frame {
        var frame = Frame()
        for timed in events where timed.at <= time {
            switch timed.event {
            case let .handTyped(text): frame.handText = text
            case .handDone: frame.handDone = true
            case .voiceListening: frame.voicePhase = .listening
            case .voiceLanding: frame.voicePhase = .landing(0)
            case .voiceDone: frame.voicePhase = .done
            }
        }
        if case .landing = frame.voicePhase {
            let start = lead + voiceListenDuration
            frame.voicePhase = .landing(min(max((time - start) / voiceLandDuration, 0), 1))
        }
        frame.handElapsed = min(max(time - lead, 0), handDuration)
        frame.voiceElapsed = min(max(time - lead, 0), voiceDuration)
        return frame
    }

    /// The finished scene, for Reduce Motion and still renders.
    static var finalFrame: Frame { frame(at: end) }

    /// "6.6 s" on the clocks.
    static func clock(_ seconds: TimeInterval) -> String {
        String(format: "%.1f s", seconds)
    }
}
