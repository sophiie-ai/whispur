import XCTest
@testable import Whispur

// MARK: - Synthetic signals

/// Deterministic test audio: no hardware, no randomness between runs.
enum SyntheticMic {
    /// A small linear congruential generator, so "noise" is the same on
    /// every run.
    struct Noise {
        private var state: UInt64
        init(seed: UInt64 = 0x5EED) { state = seed }
        /// Uniform in -1...1.
        mutating func next() -> Float {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(Int64(bitPattern: state >> 11) - (1 << 52)) / Float(1 << 52)
        }
    }

    /// Speech-like: a 120 Hz voice with eight harmonics, syllables at ~4 Hz
    /// and a pause between words every 0.9 s, over room noise. With noise,
    /// the pauses fall to the noise floor, never to exact zero; without it
    /// they are exact zero, like a noise gate.
    static func speech(seconds: Double, sampleRate: Double, noiseLevel: Float = 0.002, seed: UInt64 = 1) -> [Float] {
        var noise = Noise(seed: seed)
        let count = Int(seconds * sampleRate)
        var samples = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let t = Double(i) / sampleRate
            var voice = 0.0
            for harmonic in 1...8 {
                voice += sin(2 * .pi * 120 * Double(harmonic) * t) / Double(harmonic)
            }
            // Syllables, and a word gap every ~0.9 s.
            let syllable = 0.1 + 0.9 * max(0, sin(2 * .pi * 4 * t))
            let word = (t.truncatingRemainder(dividingBy: 0.9)) < 0.7 ? 1.0 : 0.0
            let envelope = Float(0.25 * syllable * word)
            samples[i] = envelope * Float(voice) * 0.5 + noiseLevel * noise.next()
        }
        return samples
    }

    /// Zeroes `gapSeconds` (cycling through the list) every `period`
    /// seconds of stream time, starting at `from`. The incident pattern:
    /// 25-35 ms of exact digital zero every ~135 ms.
    static func withDropouts(
        _ signal: [Float],
        sampleRate: Double,
        from: Double = 0.3,
        period: Double = 0.135,
        gapSeconds: [Double] = [0.025, 0.031, 0.035, 0.028]
    ) -> [Float] {
        var samples = signal
        var start = from
        var index = 0
        while start < Double(samples.count) / sampleRate {
            let first = Int(start * sampleRate)
            let last = min(samples.count, first + Int(gapSeconds[index % gapSeconds.count] * sampleRate))
            for i in first..<last { samples[i] = 0 }
            start += period
            index += 1
        }
        return samples
    }

    /// Feeds `signal` in `bufferFrames` buffers and returns the monitor.
    ///
    /// - deliveryRate: frames per wall-clock second (the declared rate when
    ///   nil). 2× the declared rate is the incident's clock.
    /// - startupBacklog: buffers that arrive together at the start, like
    ///   the burst queued while the engine started.
    /// - jitter: ± seconds of delivery jitter per buffer.
    static func feed(
        _ signal: [Float],
        sampleRate: Double,
        bufferFrames: Int = 4096,
        deliveryRate: Double? = nil,
        startupBacklog: Int = 0,
        startupLatency: Double = 0.2,
        jitter: Double = 0
    ) -> (monitor: MicHealthMonitor, issues: [MicHealthIssue]) {
        var monitor = MicHealthMonitor()
        monitor.reset(sampleRate: sampleRate)
        let rate = deliveryRate ?? sampleRate
        var noise = Noise(seed: 99)
        var issues: [MicHealthIssue] = []
        var frame = 0
        var buffer = 0
        let backlogEnd = Double(min(startupBacklog, max(signal.count / bufferFrames, 1)) * bufferFrames) / rate
        while frame < signal.count {
            let count = min(bufferFrames, signal.count - frame)
            let captured = Double(frame + count) / rate
            var uptime = 100 + startupLatency + captured + jitter * Double(noise.next())
            if buffer < startupBacklog { uptime = 100 + startupLatency + backlogEnd }
            let issue = signal[frame..<(frame + count)].withUnsafeBufferPointer {
                monitor.process($0, uptime: uptime)
            }
            if let issue { issues.append(issue) }
            frame += count
            buffer += 1
        }
        return (monitor, issues)
    }
}

// MARK: - Monitor

final class MicHealthMonitorTests: XCTestCase {
    private let rate48 = 48_000.0
    private let rate24 = 24_000.0

    // Healthy cases: must never fire.

    func testHealthySpeechIsNotFlagged() {
        let speech = SyntheticMic.speech(seconds: 8, sampleRate: rate48)
        let (monitor, issues) = SyntheticMic.feed(speech, sampleRate: rate48, startupBacklog: 3, jitter: 0.02)
        XCTAssertEqual(issues, [])
        XCTAssertNil(monitor.report.issue)
        XCTAssertEqual(monitor.report.dropoutCount, 0)
        XCTAssertEqual(try XCTUnwrap(monitor.report.measuredRateRatio), 1, accuracy: 0.1)
    }

    /// Bluetooth headsets in call mode run at 24 kHz with bigger, burstier
    /// buffers. That alone is fine: the day before the incident an AirPods
    /// dictation at 24 kHz transcribed perfectly.
    func testAirPodsAt24kHzButHealthyIsNotFlagged() {
        let speech = SyntheticMic.speech(seconds: 10, sampleRate: rate24, seed: 7)
        let (monitor, issues) = SyntheticMic.feed(
            speech, sampleRate: rate24, bufferFrames: 2400,
            startupBacklog: 5, startupLatency: 0.6, jitter: 0.04
        )
        XCTAssertEqual(issues, [])
        XCTAssertNil(monitor.report.issue)
        XCTAssertEqual(try XCTUnwrap(monitor.report.measuredRateRatio), 1, accuracy: 0.15)
    }

    /// A quiet room: low-level noise is never exactly flat.
    func testQuietRoomIsNotFlagged() {
        var noise = SyntheticMic.Noise(seed: 3)
        let room = (0..<Int(6 * rate48)).map { _ in 0.0015 * noise.next() }
        let (monitor, issues) = SyntheticMic.feed(room, sampleRate: rate48)
        XCTAssertEqual(issues, [])
        XCTAssertEqual(monitor.report.dropoutCount, 0)
    }

    /// A muted or digitally silent mic is all zero from the start: that's
    /// the speech gate's case, not dropouts.
    func testSilentFromTheStartIsNotDropouts() {
        let silence = [Float](repeating: 0, count: Int(5 * rate48))
        let (monitor, issues) = SyntheticMic.feed(silence, sampleRate: rate48)
        XCTAssertEqual(issues, [])
        XCTAssertEqual(monitor.report.dropoutCount, 0)
    }

    /// Leading silence before the first word, and a mute until the end,
    /// are one flat run each and never count.
    func testLeadingAndTrailingSilenceDoNotCount() {
        let lead = [Float](repeating: 0, count: Int(0.8 * rate48))
        let speech = SyntheticMic.speech(seconds: 3, sampleRate: rate48)
        let tail = [Float](repeating: 0, count: Int(2 * rate48))
        let (monitor, issues) = SyntheticMic.feed(lead + speech + tail, sampleRate: rate48)
        XCTAssertEqual(issues, [])
        XCTAssertEqual(monitor.report.dropoutCount, 0)
    }

    /// A noise gate (or voice processing) closing between words holds
    /// exact zero far longer than a dropout does; those pauses are not
    /// glitches, even several in two seconds.
    func testNoiseGatePausesAreNotDropouts() {
        // Exact zero for 200 ms between words, from the signal itself...
        var speech = SyntheticMic.speech(seconds: 6, sampleRate: rate48, noiseLevel: 0)
        // ...plus a 120 ms gate closure every 400 ms inside the words.
        var start = 0.5
        while start < 6 {
            let first = Int(start * rate48)
            for i in first..<min(speech.count, first + Int(0.12 * rate48)) { speech[i] = 0 }
            start += 0.4
        }
        let (monitor, issues) = SyntheticMic.feed(speech, sampleRate: rate48)
        XCTAssertEqual(issues, [])
        XCTAssertEqual(monitor.report.dropoutCount, 0)
    }

    /// Three dropouts in two seconds is a glitch, not a broken device.
    func testAFewIsolatedDropoutsDoNotFlag() {
        let speech = SyntheticMic.speech(seconds: 6, sampleRate: rate48)
        let sparse = SyntheticMic.withDropouts(speech, sampleRate: rate48, from: 0.5, period: 0.7)
        let (monitor, issues) = SyntheticMic.feed(sparse, sampleRate: rate48)
        XCTAssertEqual(issues, [])
        XCTAssertGreaterThan(monitor.report.dropoutCount, 3, "the runs are seen, just not dense enough to flag")
    }

    // Broken cases: must fire within 2 s.

    func testIncidentDropoutsFlagWithinTwoSeconds() throws {
        let speech = SyntheticMic.speech(seconds: 6, sampleRate: rate48)
        let broken = SyntheticMic.withDropouts(speech, sampleRate: rate48)
        let (monitor, issues) = SyntheticMic.feed(broken, sampleRate: rate48, startupBacklog: 2)
        XCTAssertEqual(issues, [.dropouts], "raised once")
        XCTAssertEqual(monitor.report.issue, .dropouts)
        XCTAssertLessThanOrEqual(try XCTUnwrap(monitor.report.flaggedAfterSeconds), 2)
        XCTAssertGreaterThan(monitor.report.dropoutCount, 30)
    }

    /// Small buffers: every 25-35 ms gap spans several of them, so a run
    /// is only seen whole if the monitor carries it across boundaries.
    func testDropoutsSpanningBufferBoundariesAreCounted() throws {
        let speech = SyntheticMic.speech(seconds: 4, sampleRate: rate48)
        let broken = SyntheticMic.withDropouts(speech, sampleRate: rate48)
        let expected = SyntheticMic.feed(broken, sampleRate: rate48).monitor.report.dropoutCount
        let (monitor, issues) = SyntheticMic.feed(broken, sampleRate: rate48, bufferFrames: 256)
        XCTAssertEqual(issues, [.dropouts])
        XCTAssertEqual(monitor.report.dropoutCount, expected, "buffer size must not change what is counted")
        XCTAssertLessThanOrEqual(try XCTUnwrap(monitor.report.flaggedAfterSeconds), 2)
    }

    func testDropoutsAt24kHzFlagWithinTwoSeconds() throws {
        let speech = SyntheticMic.speech(seconds: 5, sampleRate: rate24)
        let broken = SyntheticMic.withDropouts(speech, sampleRate: rate24)
        let (monitor, issues) = SyntheticMic.feed(broken, sampleRate: rate24, bufferFrames: 2400, jitter: 0.03)
        XCTAssertEqual(issues, [.dropouts])
        XCTAssertLessThanOrEqual(try XCTUnwrap(monitor.report.flaggedAfterSeconds), 2)
    }

    /// The incident's clock: twice as many frames as the declared rate
    /// promises, so the audio plays back at half speed.
    func testFramesAtTwiceTheDeclaredRateFlagWithinTwoSeconds() throws {
        let speech = SyntheticMic.speech(seconds: 8, sampleRate: rate24)
        let (monitor, issues) = SyntheticMic.feed(speech, sampleRate: rate24, bufferFrames: 2400, deliveryRate: 2 * rate24)
        XCTAssertEqual(issues, [.rateMismatch])
        let flaggedAfter = try XCTUnwrap(monitor.report.flaggedAfterSeconds)
        XCTAssertGreaterThanOrEqual(flaggedAfter, 1.5, "never judged before the start-up allowance")
        XCTAssertLessThanOrEqual(flaggedAfter, 2)
        XCTAssertEqual(try XCTUnwrap(monitor.report.measuredRateRatio), 2, accuracy: 0.1)
    }

    func testFramesAtHalfTheDeclaredRateFlag() throws {
        let speech = SyntheticMic.speech(seconds: 6, sampleRate: rate48)
        let (monitor, issues) = SyntheticMic.feed(speech, sampleRate: rate48, deliveryRate: rate48 / 2)
        XCTAssertEqual(issues, [.rateMismatch])
        XCTAssertLessThanOrEqual(try XCTUnwrap(monitor.report.flaggedAfterSeconds), 2.2, "one 170 ms buffer of resolution past 2 s")
    }

    /// A one-off stall that catches up is jitter, not a wrong clock.
    func testOneLateBufferDoesNotFlagTheClock() {
        var monitor = MicHealthMonitor()
        monitor.reset(sampleRate: rate48)
        let buffer = [Float](SyntheticMic.speech(seconds: 0.1, sampleRate: rate48))
        var issues: [MicHealthIssue] = []
        for index in 0..<60 {
            // Buffer 20 arrives 300 ms late, then the next ones catch up.
            var uptime = Double(index) * 0.1
            if index == 20 { uptime += 0.3 }
            if let issue = buffer.withUnsafeBufferPointer({ monitor.process($0, uptime: uptime) }) {
                issues.append(issue)
            }
        }
        XCTAssertEqual(issues, [])
    }

    func testResetClearsTheLastRecording() {
        let broken = SyntheticMic.withDropouts(SyntheticMic.speech(seconds: 3, sampleRate: rate48), sampleRate: rate48)
        var (monitor, _) = SyntheticMic.feed(broken, sampleRate: rate48)
        XCTAssertNotNil(monitor.report.issue)
        monitor.reset(sampleRate: rate48)
        XCTAssertEqual(monitor.report, MicHealthReport())
    }

    func testInt16BuffersAreChecked() {
        let broken = SyntheticMic.withDropouts(SyntheticMic.speech(seconds: 3, sampleRate: rate48), sampleRate: rate48)
        let pcm = broken.map { Int16(max(-1, min(1, $0)) * Float(Int16.max)) }
        var monitor = MicHealthMonitor()
        monitor.reset(sampleRate: rate48)
        var issues: [MicHealthIssue] = []
        var frame = 0
        while frame < pcm.count {
            let count = min(4096, pcm.count - frame)
            let uptime = Double(frame + count) / rate48
            if let issue = pcm[frame..<(frame + count)].withUnsafeBufferPointer({ monitor.process($0, uptime: uptime) }) {
                issues.append(issue)
            }
            frame += count
        }
        XCTAssertEqual(issues, [.dropouts])
    }
}

// MARK: - Diagnostics and anomaly

final class MicHealthDiagnosticsTests: XCTestCase {
    func testAudioDiagnosticsCarryTheMonitorNumbers() {
        var metrics = DiagnosticsTestSupport.speechMetrics(seconds: 2)
        metrics.micHealth = MicHealthReport(issue: .dropouts, flaggedAfterSeconds: 0.6, measuredRateRatio: 1.02, dropoutCount: 11)
        metrics.inputIsBluetooth = true
        metrics.startedAfterDeviceUnavailable = true
        let audio = DictationDiagnostics.Audio(metrics: metrics, usedEarlyCapture: false)
        XCTAssertEqual(audio.micHealthIssue, .dropouts)
        XCTAssertEqual(audio.midStreamDropouts, 11)
        XCTAssertEqual(audio.measuredRateRatio, 1.02)
        XCTAssertEqual(audio.micHealthFlaggedAfterSeconds, 0.6)
        XCTAssertEqual(audio.inputIsBluetooth, true)
        XCTAssertEqual(audio.startedAfterDeviceUnavailable, true)

        let healthy = DictationDiagnostics.Audio(metrics: DiagnosticsTestSupport.speechMetrics(), usedEarlyCapture: false)
        XCTAssertNil(healthy.micHealthIssue)
        XCTAssertEqual(healthy.midStreamDropouts, 0)
        XCTAssertNil(healthy.startedAfterDeviceUnavailable, "only a retry is written")
    }

    /// A diagnostics file written before the mic check still loads.
    func testOldRecordsWithoutTheNewFieldsDecode() throws {
        let json = """
        [{
          "id": "6F1B5A2E-3C4D-4E5F-8A9B-0C1D2E3F4A5B",
          "timestamp": "2026-11-19T08:15:00Z",
          "outcome": "success",
          "stage": "paste",
          "anomalies": ["cleanupDiverged"],
          "appVersion": "0.35.0",
          "audio": {
            "recordingSeconds": 48.0,
            "inputDeviceName": "CADefaultDeviceAggregate-1234-0",
            "inputSampleRate": 24000,
            "inputChannels": 1,
            "normalizedSeconds": 48.0,
            "normalizedSampleCount": 767318,
            "peakLevel": 0.9,
            "rmsLevel": 0.07,
            "silenceRatio": 0.3,
            "usedEarlyCapture": true
          }
        }]
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let records = try decoder.decode([DictationDiagnostics].self, from: Data(json.utf8))
        let audio = try XCTUnwrap(records.first?.audio)
        XCTAssertEqual(audio.inputSampleRate, 24_000)
        XCTAssertNil(audio.micHealthIssue)
        XCTAssertNil(audio.measuredRateRatio)
        XCTAssertNil(audio.midStreamDropouts)
        XCTAssertNil(audio.inputIsBluetooth)
        XCTAssertNil(audio.startedAfterDeviceUnavailable)
        XCTAssertEqual(records.first?.anomalies, [.cleanupDiverged])
    }

    func testNewFieldsRoundTrip() throws {
        var metrics = DiagnosticsTestSupport.speechMetrics(seconds: 2)
        metrics.micHealth = MicHealthReport(issue: .rateMismatch, flaggedAfterSeconds: 1.8, measuredRateRatio: 2.01, dropoutCount: 0)
        let record = DictationDiagnostics(outcome: .failed, audio: DictationDiagnostics.Audio(metrics: metrics, usedEarlyCapture: false))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(DictationDiagnostics.self, from: Data(record.jsonString.utf8))
        XCTAssertEqual(decoded.audio, record.audio)
    }

    func testBrokenMicAudioIsAnomalous() {
        var audio = DictationDiagnostics.Audio(metrics: DiagnosticsTestSupport.speechMetrics(), usedEarlyCapture: false)
        audio.micHealthIssue = .dropouts
        XCTAssertEqual(DictationAnomaly.reasons(for: DictationDiagnostics(outcome: .failed, audio: audio)), [.failed, .micAudioCorrupted])
        XCTAssertEqual(DictationAnomaly.reasons(for: DictationDiagnostics(outcome: .success, audio: audio)), [.micAudioCorrupted])
        XCTAssertEqual(DictationAnomaly.reasons(for: DictationDiagnostics(outcome: .cancelled, audio: audio)), [])
        audio.micHealthIssue = nil
        audio.inputIsBluetooth = true
        XCTAssertEqual(DictationAnomaly.reasons(for: DictationDiagnostics(outcome: .success, audio: audio)), [], "Bluetooth alone is context")
    }
}
