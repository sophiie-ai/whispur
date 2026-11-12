import AVFoundation
import AudioToolbox
import Combine
import CoreAudio
import Foundation
import os

private let logger = Logger(subsystem: "ai.sophiie.whispur", category: "AudioRecorder")

/// Records microphone input to a temporary file using `AVAudioEngine`.
///
/// The engine writes buffers in the input node's native format. The pipeline
/// normalizes that file to 16 kHz mono WAV before sending it to STT.
///
/// Starting the engine takes ~100 ms on a built-in mic and much longer on
/// Bluetooth or a selected non-default device, so it runs on `controlQueue`
/// instead of the main thread. Start, stop and cleanup are serialized on
/// that queue: a stop that arrives while the engine is still starting waits
/// for the start, then stops it. That serialization is what the unchecked
/// Sendable relies on.
final class AudioRecorder: ObservableObject, @unchecked Sendable {
    @Published var audioLevel: Float = 0

    var isRecording: Bool { recordingFlag.withLock { $0 } }

    /// Fires once when the first non-silent buffer arrives.
    var onRecordingReady: (() -> Void)?

    /// Receives every captured buffer on the audio thread, for streaming.
    /// Set it before `startRecording` and clear it after `stopRecording`.
    ///
    /// A recording started with `holdingAudioUntilHandler` keeps the buffers
    /// that arrive while this is nil; setting a handler replays them to it
    /// first, in order, so a stream opened late still hears the first word.
    ///
    /// The replay runs outside the lock the audio tap takes, so incoming
    /// audio never waits for the backlog: buffers that arrive meanwhile join
    /// the held ones, and the handler goes live only once nothing is held.
    var onAudioBuffer: ((AVAudioPCMBuffer) -> Void)? {
        get { audioRoute.withLockUnchecked { $0.handler } }
        set {
            guard let newValue else {
                audioRoute.withLockUnchecked { $0.handler = nil }
                return
            }
            while true {
                let backlog: [AVAudioPCMBuffer] = audioRoute.withLockUnchecked { route in
                    let held = route.held
                    route.held.removeAll()
                    if held.isEmpty {
                        route.holding = false
                        route.handler = newValue
                    }
                    return held
                }
                if backlog.isEmpty { return }
                for buffer in backlog { newValue(buffer) }
            }
        }
    }

    /// Drops audio kept for a late `onAudioBuffer` that is not coming (the
    /// recording is not streamed).
    func dropHeldAudio() {
        audioRoute.withLockUnchecked { route in
            route.held.removeAll()
            route.holding = false
        }
    }

    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var tempFileURL: URL?
    private let fileQueue = DispatchQueue(label: "ai.sophiie.whispur.audio-file", qos: .userInitiated)
    private let controlQueue = DispatchQueue(label: "ai.sophiie.whispur.audio-control", qos: .userInteractive)
    private let recordingFlag = OSAllocatedUnfairLock(initialState: false)
    /// Counts stop and discard requests when they are made, not when they
    /// run on `controlQueue`. A start given a `startTicket` refuses to open
    /// the microphone if any stop was requested since, so a stop that
    /// reached the queue before its start still wins.
    private let stopRequests = OSAllocatedUnfairLock(initialState: 0)

    /// Test seam: replaces the `AVAudioEngine` start and returns the file it
    /// "recorded" to, so start/stop ordering is testable without a microphone.
    var startEngineForTesting: (() throws -> URL)?

    /// Where tap buffers go besides the file. Locked because the handler is
    /// set on the main thread and called on the audio thread, and a replay
    /// must not let a newer buffer overtake the held ones.
    private struct AudioRoute {
        var handler: ((AVAudioPCMBuffer) -> Void)?
        var holding = false
        var held: [AVAudioPCMBuffer] = []
    }
    private let audioRoute = OSAllocatedUnfairLock(uncheckedState: AudioRoute())
    /// Enough for the few seconds an early capture can wait for a stream.
    private static let maxHeldBuffers = 128

    private var readyFired = false
    private var smoothedLevel: Float = 0
    /// Level updates are throttled to ~30 Hz on the main thread; the tap
    /// callback runs at ~47 Hz so publishing every sample is wasteful.
    private var lastLevelPublishTime: CFAbsoluteTime = 0

    private var metricSampleRate: Double = 0
    private var metricChannelCount: Int = 0
    private var metricDeviceName: String?
    private var metricTotalFrames: Int64 = 0
    private var bufferMetrics: [BufferMetric] = []

    static func requestMicrophoneAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    static var hasMicrophoneAccess: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Take one when a start is decided, before it is scheduled; pass it to
    /// `startRecording` so a stop requested in between cancels the start.
    func startTicket() -> Int {
        stopRequests.withLock { $0 }
    }

    /// Starts the engine off the main thread and returns once it runs.
    /// `holdingAudioUntilHandler` keeps the audio for an `onAudioBuffer`
    /// set after the start (see that property). With a `ticket`, throws
    /// `AudioError.startCancelled` without touching the microphone if a stop
    /// or discard was requested after the ticket was taken.
    func startRecording(holdingAudioUntilHandler: Bool = false, ticket: Int? = nil) async throws {
        audioLevel = 0
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            controlQueue.async { [self] in
                do {
                    if let ticket, stopRequests.withLock({ $0 }) != ticket {
                        throw AudioError.startCancelled
                    }
                    try startEngine(holdingAudio: holdingAudioUntilHandler)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Runs on `controlQueue`.
    private func startEngine(holdingAudio: Bool) throws {
        guard !isRecording else { return }
        if let startEngineForTesting {
            removeTempFile()
            tempFileURL = try startEngineForTesting()
            metricChannelCount = 0
            metricDeviceName = nil
            audioRoute.withLockUnchecked { route in
                route.held.removeAll()
                route.holding = holdingAudio && route.handler == nil
            }
            recordingFlag.withLock { $0 = true }
            return
        }
        let started = ProcessInfo.processInfo.systemUptime
        guard AVCaptureDevice.default(for: .audio) != nil else {
            throw AudioError.noInputDevice
        }

        removeTempFile()

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        applyPreferredInputDevice(to: inputNode)
        let inputFormat = inputNode.outputFormat(forBus: 0)
        let inputReady = ProcessInfo.processInfo.systemUptime

        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioError.noInputDevice
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("caf")

        let file = try AVAudioFile(forWriting: tempURL, settings: inputFormat.settings)

        readyFired = false
        smoothedLevel = 0
        lastLevelPublishTime = 0
        audioEngine = engine
        audioFile = file
        tempFileURL = tempURL
        metricSampleRate = inputFormat.sampleRate
        metricChannelCount = Int(inputFormat.channelCount)
        metricDeviceName = Self.currentDeviceName(of: inputNode)
        metricTotalFrames = 0
        bufferMetrics.removeAll(keepingCapacity: true)
        audioRoute.withLockUnchecked { route in
            route.held.removeAll()
            route.holding = holdingAudio && route.handler == nil
        }

        // 4096 frames is ~85 ms at 48 kHz. Asking for less does not get
        // first audio sooner: the tap's supported range starts at 100 ms.
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
            self?.handleIncomingBuffer(buffer)
        }

        engine.prepare()

        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            audioEngine = nil
            audioFile = nil
            tempFileURL = nil
            throw AudioError.recordingFailed("Audio engine failed to start: \(error.localizedDescription)")
        }

        recordingFlag.withLock { $0 = true }
        let now = ProcessInfo.processInfo.systemUptime
        logger.notice(
            """
            Recording started in \(Int((now - started) * 1000), privacy: .public) ms \
            (input node \(Int((inputReady - started) * 1000), privacy: .public) ms, \
            start \(Int((now - inputReady) * 1000), privacy: .public) ms). \
            sampleRate=\(inputFormat.sampleRate, privacy: .public) channels=\(inputFormat.channelCount, privacy: .public)
            """
        )
    }

    /// Stops the engine and returns the recording. Waits for a start that
    /// is still in flight, so it never misses an engine that is warming up.
    func stopRecording() -> (url: URL, metrics: RecordingMetrics)? {
        stopRequests.withLock { $0 &+= 1 }
        let result = controlQueue.sync { stopEngine() }
        audioLevel = 0
        return result
    }

    /// Runs on `controlQueue`.
    private func stopEngine() -> (url: URL, metrics: RecordingMetrics)? {
        guard isRecording else { return nil }

        recordingFlag.withLock { $0 = false }

        // removeTap guarantees no further tap callbacks, so bufferMetrics is
        // safe to read on the calling thread after this returns.
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil

        // Drain any pending async writes before releasing the file handle so
        // the last buffer actually lands on disk.
        fileQueue.sync {
            audioFile = nil
        }

        let metrics = RecordingMetrics(
            sampleRate: metricSampleRate,
            totalFrames: metricTotalFrames,
            buffers: bufferMetrics,
            channelCount: metricChannelCount,
            inputDeviceName: metricDeviceName
        )

        readyFired = false
        smoothedLevel = 0
        lastLevelPublishTime = 0
        dropHeldAudio()

        logger.info("Recording stopped")
        guard let url = tempFileURL else { return nil }
        return (url, metrics)
    }

    func cleanup() {
        controlQueue.sync { removeTempFile() }
    }

    /// Stops the recording and deletes its file without waiting, so a
    /// discarded early capture never blocks the main thread on an engine
    /// that is still starting. Serialized with every other start and stop.
    func discardRecording() {
        stopRequests.withLock { $0 &+= 1 }
        audioLevel = 0
        controlQueue.async { [self] in
            _ = stopEngine()
            removeTempFile()
        }
    }

    /// Waits for every queued start and stop. Tests only.
    func waitForPendingWorkForTesting() {
        controlQueue.sync {}
    }

    /// Runs on `controlQueue`.
    private func removeTempFile() {
        if let url = tempFileURL {
            try? FileManager.default.removeItem(at: url)
        }
        tempFileURL = nil
        audioFile = nil
    }

    private func applyPreferredInputDevice(to inputNode: AVAudioInputNode) {
        let uid = UserDefaults.standard.string(forKey: "preferredAudioInputUID") ?? ""
        guard !uid.isEmpty,
              var deviceID = AudioDevice.resolveDeviceID(forUID: uid),
              let audioUnit = inputNode.audioUnit
        else { return }

        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            logger.error("Failed to set preferred input device (uid=\(uid, privacy: .public) status=\(status, privacy: .public))")
        } else {
            logger.info("Using preferred input device uid=\(uid, privacy: .public) id=\(deviceID, privacy: .public)")
        }
    }

    private func handleIncomingBuffer(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }

        let (rms, peak) = levels(for: buffer)

        let frameCount = Int(buffer.frameLength)
        metricTotalFrames &+= Int64(frameCount)
        bufferMetrics.append(BufferMetric(frameCount: frameCount, rms: rms, peak: peak))

        if !readyFired && rms > 0 {
            readyFired = true
            DispatchQueue.main.async { [weak self] in
                self?.onRecordingReady?()
            }
        }

        // Hand the buffer off to the writer queue async so the audio tap
        // callback never stalls on disk I/O. `fileQueue` is serial and
        // flushed synchronously in `stopRecording`, so ordering is preserved
        // and no write is lost.
        fileQueue.async { [weak self] in
            guard let self, let audioFile = self.audioFile else { return }
            do {
                try audioFile.write(from: buffer)
            } catch {
                logger.error("Failed to write audio buffer: \(error.localizedDescription, privacy: .public)")
            }
        }

        // Only the hand-off happens under the lock; the handler runs after.
        // The tap is the only caller, so its buffers stay in order.
        let handler: ((AVAudioPCMBuffer) -> Void)? = audioRoute.withLockUnchecked { route in
            if let handler = route.handler { return handler }
            if route.holding, route.held.count < Self.maxHeldBuffers {
                route.held.append(buffer)
            }
            return nil
        }
        handler?(buffer)

        let scaledLevel = min(rms * 12, 1)
        if scaledLevel > smoothedLevel {
            smoothedLevel = (smoothedLevel * 0.25) + (scaledLevel * 0.75)
        } else {
            smoothedLevel = (smoothedLevel * 0.7) + (scaledLevel * 0.3)
        }

        // Throttle UI publishes to ~30 Hz. The tap fires at ~47 Hz; the
        // waveform and level meter can't visually distinguish anything
        // faster, so batching cuts main-thread dispatch overhead.
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastLevelPublishTime >= 1.0 / 30.0 {
            lastLevelPublishTime = now
            let published = smoothedLevel
            DispatchQueue.main.async { [weak self] in
                self?.audioLevel = published
            }
        }
    }

    /// RMS and peak of the first channel, both 0...1.
    private func levels(for buffer: AVAudioPCMBuffer) -> (rms: Float, peak: Float) {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return (0, 0) }

        if let channelData = buffer.floatChannelData {
            var sum: Float = 0
            var peak: Float = 0
            for frame in 0..<frameCount {
                let sample = channelData[0][frame]
                sum += sample * sample
                peak = max(peak, abs(sample))
            }
            return (sqrt(sum / Float(frameCount)), peak)
        }

        if let channelData = buffer.int16ChannelData {
            var sum: Float = 0
            var peak: Float = 0
            for frame in 0..<frameCount {
                let sample = Float(channelData[0][frame]) / Float(Int16.max)
                sum += sample * sample
                peak = max(peak, abs(sample))
            }
            return (sqrt(sum / Float(frameCount)), peak)
        }

        return (0, 0)
    }

    /// The name of the device the input node records from, for diagnostics.
    private static func currentDeviceName(of inputNode: AVAudioInputNode) -> String? {
        guard let audioUnit = inputNode.audioUnit else { return nil }
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            &size
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return AudioDevice.name(of: deviceID)
    }
}

/// Per-buffer RMS and peak captured during recording.
struct BufferMetric {
    let frameCount: Int
    let rms: Float
    /// The loudest sample in the buffer, 0...1.
    var peak: Float = 0
}

/// Raw voice-activity data collected while recording. Used by the pipeline to
/// decide whether the recording contains enough real speech to send to STT.
struct RecordingMetrics {
    let sampleRate: Double
    let totalFrames: Int64
    let buffers: [BufferMetric]
    /// Input channels, for diagnostics. 0 when unknown.
    var channelCount: Int = 0
    /// The input device's name, for diagnostics.
    var inputDeviceName: String?

    var totalDurationSeconds: Double {
        sampleRate > 0 ? Double(totalFrames) / sampleRate : 0
    }
}

enum AudioError: LocalizedError {
    case noInputDevice
    case recordingFailed(String)
    case microphoneNotAuthorized
    case startCancelled

    var errorDescription: String? {
        switch self {
        case .noInputDevice:
            return "No microphone input device is available."
        case .recordingFailed(let message):
            return message
        case .microphoneNotAuthorized:
            return "Microphone access is not authorized."
        case .startCancelled:
            return "The recording was stopped before it started."
        }
    }
}
