import Foundation
import CoreAudio

struct AudioInputDeviceInfo: Codable, Equatable, Identifiable {
    var uid: String
    var name: String
    var sampleRate: Double
    var inputChannelCount: Int
    var isDefault: Bool

    var id: String { uid }
}

enum AudioDeviceCatalog {
    enum DeviceError: LocalizedError {
        case deviceNotFound(String)
        case readDevicesFailed(OSStatus)
        case readUIDFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .deviceNotFound(let uid):
                return "Input device not found: \(uid)"
            case .readDevicesFailed(let status):
                return "Could not read audio devices (OSStatus \(status))."
            case .readUIDFailed(let status):
                return "Could not read audio device UID (OSStatus \(status))."
            }
        }
    }

    static func inputDevices() -> [AudioInputDeviceInfo] {
        let defaultID = defaultInputDeviceID()
        return allDevices().compactMap { deviceID in
            let channels = inputChannelCount(deviceID)
            guard channels > 0, let uid = try? deviceUID(deviceID) else { return nil }
            return AudioInputDeviceInfo(
                uid: uid,
                name: deviceName(deviceID),
                sampleRate: nominalSampleRate(deviceID),
                inputChannelCount: channels,
                isDefault: deviceID == defaultID
            )
        }
        .sorted { lhs, rhs in
            if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    static func defaultInputDevice() -> AudioInputDeviceInfo? {
        guard let deviceID = defaultInputDeviceID(),
              inputChannelCount(deviceID) > 0,
              let uid = try? deviceUID(deviceID) else {
            return nil
        }
        return AudioInputDeviceInfo(
            uid: uid,
            name: deviceName(deviceID),
            sampleRate: nominalSampleRate(deviceID),
            inputChannelCount: inputChannelCount(deviceID),
            isDefault: true
        )
    }

    static func inputDeviceID(uid: String) throws -> AudioDeviceID {
        for deviceID in allDevices() where inputChannelCount(deviceID) > 0 {
            if try deviceUID(deviceID) == uid {
                return deviceID
            }
        }
        throw DeviceError.deviceNotFound(uid)
    }

    private static func allDevices() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        )
        guard status == noErr, dataSize >= UInt32(MemoryLayout<AudioDeviceID>.size) else {
            return []
        }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: kAudioObjectUnknown, count: count)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &devices
        )
        guard status == noErr else { return [] }
        return devices.filter { $0 != kAudioObjectUnknown }
    }

    private static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    private static func deviceUID(_ deviceID: AudioDeviceID) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfUID: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &cfUID)
        guard status == noErr, let uid = cfUID?.takeRetainedValue() else {
            throw DeviceError.readUIDFailed(status)
        }
        return uid as String
    }

    private static func deviceName(_ deviceID: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfName: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &cfName)
        guard status == noErr, let name = cfName?.takeRetainedValue() else {
            return "Unknown Input Device"
        }
        return name as String
    }

    private static func nominalSampleRate(_ deviceID: AudioDeviceID) -> Double {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var sampleRate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &sampleRate)
        return status == noErr ? sampleRate : 0
    }

    private static func inputChannelCount(_ deviceID: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)
        guard status == noErr, dataSize >= UInt32(MemoryLayout<AudioBufferList>.size) else {
            return 0
        }

        let rawPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawPointer.deallocate() }

        status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, rawPointer)
        guard status == noErr else { return 0 }

        let bufferList = rawPointer.bindMemory(to: AudioBufferList.self, capacity: 1)
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
