import AVFoundation
import CoreAudio
import Foundation

struct DeviceInfo {
    var id: AudioObjectID
    var name: String
    var uid: String
    var inputChannels: UInt32
    var outputChannels: UInt32
    var isDefaultInput: Bool
    var isDefaultOutput: Bool
    var isDefaultSystemOutput: Bool
}

func readString(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
    guard status == noErr, let string = value?.takeRetainedValue() else {
        return ""
    }
    return string as String
}

func channelCount(_ objectID: AudioObjectID, scope: AudioObjectPropertyScope) -> UInt32 {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size) == noErr, size > 0 else {
        return 0
    }
    let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(size))
    defer { bufferList.deallocate() }
    guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, bufferList) == noErr else {
        return 0
    }
    let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
    return buffers.reduce(UInt32(0)) { $0 + $1.mNumberChannels }
}

func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioObjectID {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var id = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    _ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
    return id
}

func allDevices() -> [AudioObjectID] {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else {
        return []
    }
    let count = Int(size) / MemoryLayout<AudioObjectID>.size
    var ids = Array(repeating: AudioObjectID(kAudioObjectUnknown), count: count)
    _ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids)
    return ids
}

let defaultInput = defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
let defaultOutput = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
let defaultSystemOutput = defaultDevice(kAudioHardwarePropertyDefaultSystemOutputDevice)

let devices = allDevices().map { id in
    DeviceInfo(
        id: id,
        name: readString(id, kAudioObjectPropertyName),
        uid: readString(id, kAudioDevicePropertyDeviceUID),
        inputChannels: channelCount(id, scope: kAudioDevicePropertyScopeInput),
        outputChannels: channelCount(id, scope: kAudioDevicePropertyScopeOutput),
        isDefaultInput: id == defaultInput,
        isDefaultOutput: id == defaultOutput,
        isDefaultSystemOutput: id == defaultSystemOutput
    )
}

for device in devices.sorted(by: { $0.name < $1.name }) {
    let roles = [
        device.isDefaultInput ? "default-input" : nil,
        device.isDefaultOutput ? "default-output" : nil,
        device.isDefaultSystemOutput ? "default-system-output" : nil
    ].compactMap { $0 }.joined(separator: ",")
    print("\(device.id)\t\(device.name)\tuid=\(device.uid)\tin=\(device.inputChannels)\tout=\(device.outputChannels)\t\(roles)")
}
