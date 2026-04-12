import AVFoundation
import CoreAudio
import Foundation

/// Represents an audio input device.
struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
    let uid: String

    /// List all available audio input devices.
    static func availableInputDevices() -> [AudioDevice] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            &dataSize
        )
        guard status == noErr else { return [] }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)

        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            &dataSize,
            &deviceIDs
        )
        guard status == noErr else { return [] }

        return deviceIDs.compactMap { deviceID -> AudioDevice? in
            // Check if device has input channels
            var inputAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )

            var bufferListSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(deviceID, &inputAddress, 0, nil, &bufferListSize) == noErr else {
                return nil
            }

            let bufferListPointer = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
            defer { bufferListPointer.deallocate() }

            guard AudioObjectGetPropertyData(deviceID, &inputAddress, 0, nil, &bufferListSize, bufferListPointer) == noErr else {
                return nil
            }

            let bufferList = bufferListPointer.pointee
            guard bufferList.mNumberBuffers > 0, bufferList.mBuffers.mNumberChannels > 0 else {
                return nil
            }

            // Get device name
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceNameCFString,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var name: CFString = "" as CFString
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &name)

            // Get device UID
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var uid: CFString = "" as CFString
            var uidSize = UInt32(MemoryLayout<CFString>.size)
            AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, &uid)

            return AudioDevice(
                id: deviceID,
                name: name as String,
                uid: uid as String
            )
        }
    }
}
