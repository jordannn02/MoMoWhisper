import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

struct AudioInputDevice: Identifiable, Hashable {
    static let systemDefaultID = "system-default"

    let id: String
    let name: String
    let audioDeviceID: AudioDeviceID?

    static let systemDefault = AudioInputDevice(
        id: systemDefaultID,
        name: "系統預設麥克風",
        audioDeviceID: nil
    )
}

enum AudioInputDeviceProvider {
    static func inputDevices() -> [AudioInputDevice] {
        let devices = availableAudioDeviceIDs()
            .filter { hasInputStreams(deviceID: $0) }
            .compactMap { deviceID -> AudioInputDevice? in
                guard let name = deviceName(deviceID: deviceID) else {
                    return nil
                }

                return AudioInputDevice(
                    id: String(deviceID),
                    name: name,
                    audioDeviceID: deviceID
                )
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        return [AudioInputDevice.systemDefault] + devices
    }

    static func selectedDeviceID(for selection: String) throws -> AudioDeviceID {
        if selection == AudioInputDevice.systemDefaultID {
            return try defaultInputDeviceID()
        }

        guard let rawValue = UInt32(selection) else {
            throw AudioInputDeviceError.invalidSelection
        }

        return AudioDeviceID(rawValue)
    }

    static func applyInputDevice(selection: String, to inputNode: AVAudioInputNode) throws {
        guard let audioUnit = inputNode.audioUnit else {
            throw AudioInputDeviceError.missingAudioUnit
        }

        var deviceID = try selectedDeviceID(for: selection)
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )

        guard status == noErr else {
            throw AudioInputDeviceError.coreAudioStatus(status)
        }
    }

    private static func availableAudioDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        ) == noErr else {
            return []
        }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: AudioDeviceID(), count: count)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceIDs
        )

        guard status == noErr else {
            return []
        }

        return deviceIDs
    }

    private static func hasInputStreams(deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(
            deviceID,
            &address,
            0,
            nil,
            &dataSize
        )

        return status == noErr && dataSize > 0
    }

    private static func deviceName(deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var unmanagedName: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &unmanagedName) { pointer in
            AudioObjectGetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                &dataSize,
                UnsafeMutableRawPointer(pointer)
            )
        }

        guard status == noErr, let unmanagedName else {
            return nil
        }

        return unmanagedName.takeUnretainedValue() as String
    }

    private static func defaultInputDeviceID() throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID = AudioDeviceID()
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceID
        )

        guard status == noErr else {
            throw AudioInputDeviceError.coreAudioStatus(status)
        }

        return deviceID
    }
}

private enum AudioInputDeviceError: LocalizedError {
    case invalidSelection
    case missingAudioUnit
    case coreAudioStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidSelection:
            return "麥克風選擇無效。"
        case .missingAudioUnit:
            return "無法取得麥克風音訊單元。"
        case .coreAudioStatus(let status):
            return "切換麥克風失敗：CoreAudio \(status)"
        }
    }
}
