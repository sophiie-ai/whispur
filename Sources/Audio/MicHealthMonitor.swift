import Foundation

/// What the live microphone check found wrong with a recording.
enum MicHealthIssue: String, Codable, Equatable, CaseIterable {
    /// Frames arrive much faster or slower than the input's declared sample
    /// rate, so the audio plays back sped up or slowed down. Seen when a
    /// Bluetooth headset switches profile while the engine starts.
    case rateMismatch
    /// The signal keeps cutting to exactly flat samples for a few
    /// milliseconds at a time, mid-speech: the device is dropping audio.
    case dropouts
}

/// The monitor's numbers at the end of a recording, for diagnostics.
struct MicHealthReport: Equatable {
    /// The first problem found, or nil when the audio looked healthy.
    var issue: MicHealthIssue?
    /// Wall-clock seconds from the first buffer to the flag.
    var flaggedAfterSeconds: Double?
    /// Frames received per second divided by the declared sample rate, over
    /// the whole recording. Nil until enough wall-clock time has passed to
    /// measure it.
    var measuredRateRatio: Double?
    /// Flat runs that started after the signal had been live and ended
    /// before the recording did.
    var dropoutCount: Int = 0
}

/// Watches raw tap buffers for audio that a broken input path produces:
/// a clock that does not match the declared sample rate, and short runs of
/// exactly flat samples in the middle of speech.
///
/// A value type with fixed storage, fed on the audio thread: `process`
/// does not allocate. Times are passed in, so tests drive it with
/// synthetic signals and a fake clock.
///
/// A Bluetooth input or a 24 kHz rate is not a problem by itself; only the
/// two measured symptoms are. A mic that is silent from the start (muted,
/// or digital silence) is never called dropouts: flat runs only count once
/// the signal has been live.
struct MicHealthMonitor {
    struct Thresholds: Equatable {
        /// Wall-clock time before the clock check starts judging. Long
        /// enough that the start-up burst (buffers queued while the engine
        /// started) can't push the ratio out of range on its own.
        var minClockSeconds: Double = 1.5
        var allowedRateRatio: ClosedRange<Double> = 0.8...1.25
        /// How long the ratio must stay out of range before it counts, so a
        /// single late or bunched buffer can't trip it.
        var rateMismatchPersistSeconds: Double = 0.25
        /// Shortest flat run that counts as a dropout.
        var minDropoutSeconds: Double = 0.005
        /// Longest flat run that counts as a dropout. The incident's runs
        /// were 5-35 ms; longer ones are a mute, a pause behind a noise gate
        /// or voice processing, or the end of the audio, not a glitch.
        var maxDropoutSeconds: Double = 0.1
        /// Dropouts within `dropoutWindowSeconds` of each other that flag
        /// the recording.
        var dropoutsToFlag: Int = 4
        /// Measured in stream time (frames / declared rate).
        var dropoutWindowSeconds: Double = 2
        /// A sample at least this loud means the signal is live, so later
        /// flat runs are dropouts rather than leading silence.
        var liveSignalLevel: Float = 0.001
        /// Flat runs at or above this level are clipping, not dropouts.
        var clippingLevel: Float = 0.9
    }

    let thresholds: Thresholds

    private(set) var report = MicHealthReport()

    private var sampleRate: Double = 0
    private var firstBufferUptime: Double?
    private var firstBufferFrames: Int64 = 0
    private var totalFrames: Int64 = 0
    private var rateOutOfRangeSince: Double?

    private var signalLive = false
    private var hasPrevious = false
    private var previous: Float = 0
    /// Consecutive samples equal to `previous`, including the first.
    private var runLength = 0
    /// The current run started after the signal went live.
    private var runCounts = false
    private var minRunFrames = 0
    private var maxRunFrames = 0
    /// Stream times of the latest dropouts, a ring of `dropoutsToFlag`.
    private var recentDropouts: [Double]
    private var recentDropoutIndex = 0

    init(thresholds: Thresholds = Thresholds()) {
        self.thresholds = thresholds
        recentDropouts = Array(repeating: -.infinity, count: max(thresholds.dropoutsToFlag, 1))
    }

    /// Clears everything for a new recording at `sampleRate`. Keeps the
    /// storage, so it is safe on the audio thread.
    mutating func reset(sampleRate: Double) {
        report = MicHealthReport()
        self.sampleRate = sampleRate
        firstBufferUptime = nil
        firstBufferFrames = 0
        totalFrames = 0
        rateOutOfRangeSince = nil
        signalLive = false
        hasPrevious = false
        previous = 0
        runLength = 0
        runCounts = false
        minRunFrames = max(1, Int((thresholds.minDropoutSeconds * sampleRate).rounded(.up)))
        maxRunFrames = max(minRunFrames, Int(thresholds.maxDropoutSeconds * sampleRate))
        for index in recentDropouts.indices { recentDropouts[index] = -.infinity }
        recentDropoutIndex = 0
    }

    /// Feeds one buffer's first channel, received at `uptime` (seconds on
    /// any monotonic clock). Returns the issue when this buffer is the one
    /// that raises it; nil otherwise, including after the first flag.
    mutating func process(_ samples: UnsafeBufferPointer<Float>, uptime: Double) -> MicHealthIssue? {
        process(count: samples.count, uptime: uptime) { samples[$0] }
    }

    /// Int16 buffers, scaled to -1...1.
    mutating func process(_ samples: UnsafeBufferPointer<Int16>, uptime: Double) -> MicHealthIssue? {
        process(count: samples.count, uptime: uptime) { Float(samples[$0]) / Float(Int16.max) }
    }

    private mutating func process(count: Int, uptime: Double, sample: (Int) -> Float) -> MicHealthIssue? {
        guard count > 0, sampleRate > 0 else { return nil }
        let alreadyFlagged = report.issue != nil

        scanForDropouts(count: count, sample: sample)
        totalFrames += Int64(count)
        checkClock(frames: count, uptime: uptime)

        guard !alreadyFlagged, let issue = report.issue else { return nil }
        if let first = firstBufferUptime {
            report.flaggedAfterSeconds = max(0, uptime - first)
        }
        return issue
    }

    private mutating func scanForDropouts(count: Int, sample: (Int) -> Float) {
        for index in 0..<count {
            let value = sample(index)
            if hasPrevious, value == previous {
                runLength += 1
            } else {
                if hasPrevious { endRun(atFrame: totalFrames + Int64(index)) }
                hasPrevious = true
                previous = value
                runLength = 1
                runCounts = signalLive
            }
            if !signalLive, abs(value) >= thresholds.liveSignalLevel {
                signalLive = true
            }
        }
    }

    /// The flat run before `frame` ended because the signal moved again. A
    /// run still open when the recording stops never counts.
    private mutating func endRun(atFrame frame: Int64) {
        guard runCounts,
              runLength >= minRunFrames,
              runLength <= maxRunFrames,
              abs(previous) < thresholds.clippingLevel
        else { return }
        report.dropoutCount += 1
        let streamTime = Double(frame) / sampleRate
        recentDropouts[recentDropoutIndex] = streamTime
        recentDropoutIndex = (recentDropoutIndex + 1) % recentDropouts.count
        // After the write, the index points at the oldest of the ring.
        let oldest = recentDropouts[recentDropoutIndex]
        if report.issue == nil, streamTime - oldest <= thresholds.dropoutWindowSeconds {
            report.issue = .dropouts
        }
    }

    private mutating func checkClock(frames: Int, uptime: Double) {
        guard let first = firstBufferUptime else {
            // A buffer arrives once its frames were captured, so the first
            // one's frames predate the clock; count from the ones after it.
            firstBufferUptime = uptime
            firstBufferFrames = Int64(frames)
            return
        }
        let elapsed = uptime - first
        guard elapsed >= thresholds.minClockSeconds else { return }
        let ratio = Double(totalFrames - firstBufferFrames) / sampleRate / elapsed
        report.measuredRateRatio = ratio
        guard !thresholds.allowedRateRatio.contains(ratio) else {
            rateOutOfRangeSince = nil
            return
        }
        let since = rateOutOfRangeSince ?? uptime
        rateOutOfRangeSince = since
        if report.issue == nil, uptime - since >= thresholds.rateMismatchPersistSeconds {
            report.issue = .rateMismatch
        }
    }
}
