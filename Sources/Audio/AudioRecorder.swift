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
    var onAudioBuffer: ((AVAudioPCMBuffer) -> Void)?

    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var tempFileURL: URL?
    private let fileQueue = DispatchQueue(label: "ai.sophiie.whispur.audio-file", qos: .userInitiated)
    private let controlQueue = DispatchQueue(label: "ai.sophiie.whispur.audio-control", qos: .userInteractive)
    private let recordingFlag = OSAllocatedUnfairLock(initialState: false)

    private var readyFired = false
    private var smoothedLevel: Float = 0
    /// Level updates are throttled to ~30 Hz on the main thread; the tap
    /// callback runs at ~47 Hz so publishing every sample is wasteful.
    private var lastLevelPublishTime: CFAbsoluteTime = 0

    private var metricSampleRate: Double = 0
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

    /// Starts the engine off the main thread and returns once it runs.
    func startRecording() async throws {
        audioLevel = 0
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            controlQueue.async { [self] in
                do {
                    try startEngine()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Runs on `controlQueue`.
    private func startEngine() throws {
        guard !isRecording else { return }
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
        metricTotalFrames = 0
        bufferMetrics.removeAll(keepingCapacity: true)

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
        logger.info(
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
            buffers: bufferMetrics
        )

        readyFired = false
        smoothedLevel = 0
        lastLevelPublishTime = 0

        logger.info("Recording stopped")
        guard let url = tempFileURL else { return nil }
        return (url, metrics)
    }

    func cleanup() {
        controlQueue.sync { removeTempFile() }
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

        let rms = rmsLevel(for: buffer)

        let frameCount = Int(buffer.frameLength)
        metricTotalFrames &+= Int64(frameCount)
        bufferMetrics.append(BufferMetric(frameCount: frameCount, rms: rms))

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

        onAudioBuffer?(buffer)

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

    private func rmsLevel(for buffer: AVAudioPCMBuffer) -> Float {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return 0 }

        if let channelData = buffer.floatChannelData {
            var sum: Float = 0
            for frame in 0..<frameCount {
                let sample = channelData[0][frame]
                sum += sample * sample
            }
            return sqrt(sum / Float(frameCount))
        }

        if let channelData = buffer.int16ChannelData {
            var sum: Float = 0
            for frame in 0..<frameCount {
                let sample = Float(channelData[0][frame]) / Float(Int16.max)
                sum += sample * sample
            }
            return sqrt(sum / Float(frameCount))
        }

        return 0
    }
}

/// Per-buffer RMS captured during recording.
struct BufferMetric {
    let frameCount: Int
    let rms: Float
}

/// Raw voice-activity data collected while recording. Used by the pipeline to
/// decide whether the recording contains enough real speech to send to STT.
struct RecordingMetrics {
    let sampleRate: Double
    let totalFrames: Int64
    let buffers: [BufferMetric]

    var totalDurationSeconds: Double {
        sampleRate > 0 ? Double(totalFrames) / sampleRate : 0
    }
}

enum AudioError: LocalizedError {
    case noInputDevice
    case recordingFailed(String)
    case microphoneNotAuthorized

    var errorDescription: String? {
        switch self {
        case .noInputDevice:
            return "No microphone input device is available."
        case .recordingFailed(let message):
            return message
        case .microphoneNotAuthorized:
            return "Microphone access is not authorized."
        }
    }
}
