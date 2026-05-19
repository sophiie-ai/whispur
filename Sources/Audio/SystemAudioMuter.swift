import CoreAudio
import Foundation
import os

private let logger = Logger(subsystem: "ai.sophiie.whispur", category: "SystemAudioMuter")

/// Ducks (or fully mutes) the system default output device while dictation is
/// active and restores the prior volume state when recording ends.
///
/// Background audio (YouTube, music, video calls) keeps playing — we only
/// reduce output so it doesn't bleed back into the microphone or compete with
/// the user's voice. The reduction is configurable: `reductionPercent = 100`
/// is full mute (parity with the original feature), lower values just duck
/// playback so the user can still hear what's happening.
///
/// Volume is always driven through `kAudioDevicePropertyVolumeScalar`. We
/// avoid `kAudioDevicePropertyMute` so we can apply a fractional reduction
/// uniformly and restore the exact previous level. Both the master element
/// (0) and per-channel elements are probed; whichever ones the device exposes
/// as settable are captured and restored.
@MainActor
final class SystemAudioMuter {
    private struct ChannelLevel {
        let element: UInt32
        let previousVolume: Float32
    }

    private struct SavedState {
        let deviceID: AudioDeviceID
        let channels: [ChannelLevel]
    }

    private var saved: SavedState?

    var isActive: Bool { saved != nil }

    /// Apply a 0...100 reduction (percent) to the default output device.
    /// `100` is full mute. Values outside the range are clamped. No-op if
    /// already active or if no controllable output device is available.
    func mute(reductionPercent: Int) {
        guard saved == nil else { return }
        let clamped = max(0, min(100, reductionPercent))
        guard clamped > 0 else {
            logger.info("Skipping mute: reductionPercent is 0")
            return
        }

        guard let deviceID = Self.defaultOutputDevice() else {
            logger.warning("No default output device found; skipping mute")
            return
        }

        let channels = Self.settableVolumeElements(deviceID: deviceID)
        guard !channels.isEmpty else {
            logger.warning("Output device exposes no settable volume control; skipping mute")
            return
        }

        let factor = Float32(1 - Double(clamped) / 100.0)
        for entry in channels {
            let target = max(0, entry.previousVolume * factor)
            Self.setChannelVolume(deviceID: deviceID, element: entry.element, volume: target)
        }
        saved = SavedState(deviceID: deviceID, channels: channels)
        logger.info("Ducked system output by \(clamped, privacy: .public)% across \(channels.count, privacy: .public) element(s)")
    }

    /// Restore the device state captured by the most recent `mute()` call.
    /// Idempotent: a no-op if nothing was ducked.
    func restore() {
        guard let state = saved else { return }

        var anyFailed = false
        for entry in state.channels {
            if !Self.setChannelVolume(
                deviceID: state.deviceID,
                element: entry.element,
                volume: entry.previousVolume
            ) {
                anyFailed = true
            }
        }

        // Only drop the saved state if every write succeeded; otherwise a
        // later retry (e.g. after the user reconnects a flaky AirPlay sink)
        // can still recover. The pipeline cleanup paths each call restore,
        // so a subsequent recording's stop will naturally retry.
        if anyFailed {
            logger.warning("Some volume writes failed during restore; keeping saved state for retry")
            return
        }
        saved = nil
        logger.info("Restored system output volumes")
    }

    // MARK: - CoreAudio helpers

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0, nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    /// Returns the output elements we'll drive to apply the requested
    /// reduction. Per Apple's QA1016, a device may expose master-only,
    /// per-channel-only, both, or neither volume control. When a device
    /// exposes both, we prefer the master element — driving both planes
    /// would stack independent gain stages and over-attenuate (a 50%
    /// reduction on each becomes 75% combined). When master isn't settable,
    /// we fall back to every per-channel element the device reports.
    ///
    /// Channel count is derived from `kAudioDevicePropertyStreamConfiguration`
    /// instead of hard-coding a maximum, so aggregate or multichannel
    /// devices with more than eight outputs are covered.
    private static func settableVolumeElements(deviceID: AudioDeviceID) -> [ChannelLevel] {
        if let masterVolume = readVolume(deviceID: deviceID, element: kAudioObjectPropertyElementMain) {
            return [ChannelLevel(element: kAudioObjectPropertyElementMain, previousVolume: masterVolume)]
        }

        var results: [ChannelLevel] = []
        let channelCount = outputChannelCount(deviceID: deviceID)
        if channelCount > 0 {
            for channel in 1...channelCount {
                if let level = readVolume(deviceID: deviceID, element: channel) {
                    results.append(ChannelLevel(element: channel, previousVolume: level))
                }
            }
        }
        return results
    }

    private static func outputChannelCount(deviceID: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr, dataSize > 0 else {
            return 0
        }
        let bufferList = UnsafeMutableRawPointer.allocate(byteCount: Int(dataSize), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { bufferList.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, bufferList) == noErr else {
            return 0
        }
        let abl = UnsafeMutableAudioBufferListPointer(bufferList.assumingMemoryBound(to: AudioBufferList.self))
        var total: UInt32 = 0
        for buffer in abl {
            total &+= buffer.mNumberChannels
        }
        return total
    }

    private static func readVolume(deviceID: AudioDeviceID, element: UInt32) -> Float32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var settable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr,
              settable.boolValue else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }

    @discardableResult
    private static func setChannelVolume(deviceID: AudioDeviceID, element: UInt32, volume: Float32) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
        var value = volume
        let status = AudioObjectSetPropertyData(
            deviceID,
            &address,
            0, nil,
            UInt32(MemoryLayout<Float32>.size),
            &value
        )
        return status == noErr
    }
}
