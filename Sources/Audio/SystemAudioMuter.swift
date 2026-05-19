import CoreAudio
import Foundation
import os

private let logger = Logger(subsystem: "ai.sophiie.whispur", category: "SystemAudioMuter")

/// Mutes the system default output device while dictation is active and
/// restores the prior state when recording ends.
///
/// Background audio (YouTube, music, etc.) keeps playing — we only silence the
/// output so it doesn't bleed back into the microphone or compete with the
/// user's voice. Prefers the device's `kAudioDevicePropertyMute` and falls back
/// to driving per-channel volume to zero when the device doesn't expose a
/// settable mute.
final class SystemAudioMuter {
    private struct SavedState {
        let deviceID: AudioDeviceID
        let usedMuteProperty: Bool
        let previousMute: UInt32?
        let previousVolumes: [(channel: UInt32, volume: Float32)]
    }

    private var saved: SavedState?

    var isActive: Bool { saved != nil }

    /// Capture the current output state and mute it. No-op if already muted by
    /// this instance, or if no controllable output device is available.
    func mute() {
        guard saved == nil else { return }
        guard let deviceID = Self.defaultOutputDevice() else {
            logger.warning("No default output device found; skipping mute")
            return
        }

        if let previousMute = Self.readMuteProperty(deviceID: deviceID),
           Self.setMuteProperty(deviceID: deviceID, mute: 1) {
            saved = SavedState(
                deviceID: deviceID,
                usedMuteProperty: true,
                previousMute: previousMute,
                previousVolumes: []
            )
            logger.info("Muted system output via mute property")
            return
        }

        let volumes = Self.readChannelVolumes(deviceID: deviceID)
        guard !volumes.isEmpty else {
            logger.warning("Output device exposes neither a settable mute nor channel volumes")
            return
        }
        for entry in volumes {
            Self.setChannelVolume(deviceID: deviceID, channel: entry.channel, volume: 0)
        }
        saved = SavedState(
            deviceID: deviceID,
            usedMuteProperty: false,
            previousMute: nil,
            previousVolumes: volumes
        )
        logger.info("Muted system output via channel-volume fallback")
    }

    /// Restore the device state captured by the most recent `mute()` call.
    /// Idempotent: a no-op if nothing was muted.
    func restore() {
        guard let state = saved else { return }
        saved = nil

        if state.usedMuteProperty, let previousMute = state.previousMute {
            _ = Self.setMuteProperty(deviceID: state.deviceID, mute: previousMute)
            logger.info("Restored system output mute state")
            return
        }
        for entry in state.previousVolumes {
            Self.setChannelVolume(deviceID: state.deviceID, channel: entry.channel, volume: entry.volume)
        }
        logger.info("Restored system output channel volumes")
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

    private static func readMuteProperty(deviceID: AudioDeviceID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var settable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr,
              settable.boolValue else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }

    private static func setMuteProperty(deviceID: AudioDeviceID, mute: UInt32) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = mute
        let status = AudioObjectSetPropertyData(
            deviceID,
            &address,
            0, nil,
            UInt32(MemoryLayout<UInt32>.size),
            &value
        )
        return status == noErr
    }

    private static func readChannelVolumes(deviceID: AudioDeviceID) -> [(channel: UInt32, volume: Float32)] {
        var results: [(UInt32, Float32)] = []
        // CoreAudio output volume controls live on the per-channel elements
        // (1...N). The main element (0) often has no settable volume control.
        for channel in 1...8 {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: UInt32(channel)
            )
            guard AudioObjectHasProperty(deviceID, &address) else { continue }
            var settable = DarwinBoolean(false)
            guard AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr,
                  settable.boolValue else { continue }
            var value: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else {
                continue
            }
            results.append((UInt32(channel), value))
        }
        return results
    }

    private static func setChannelVolume(deviceID: AudioDeviceID, channel: UInt32, volume: Float32) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: channel
        )
        var value = volume
        _ = AudioObjectSetPropertyData(
            deviceID,
            &address,
            0, nil,
            UInt32(MemoryLayout<Float32>.size),
            &value
        )
    }
}
