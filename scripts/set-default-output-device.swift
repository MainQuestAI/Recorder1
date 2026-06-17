import CoreAudio
import Foundation

enum SetOutputError: LocalizedError {
    case usage
    case missingDevice(String)
    case setFailed(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .usage:
            return "usage: swift scripts/set-default-output-device.swift <device-uid>"
        case .missingDevice(let uid):
            return "output device not found for uid: \(uid)"
        case .setFailed(let label, let status):
            return "\(label) failed with OSStatus \(status)"
        }
    }
}

func allDevices() throws -> [AudioObjectID] {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    var status = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
    guard status == noErr else { throw SetOutputError.setFailed("AudioObjectGetPropertyDataSize", status) }
    let count = Int(size) / MemoryLayout<AudioObjectID>.size
    var devices = Array(repeating: AudioObjectID(kAudioObjectUnknown), count: count)
    status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices)
    guard status == noErr else { throw SetOutputError.setFailed("AudioObjectGetPropertyData", status) }
    return devices
}

func uid(_ deviceID: AudioObjectID) -> String? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceUID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var cfUID: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &cfUID)
    guard status == noErr, let value = cfUID?.takeRetainedValue() else { return nil }
    return value as String
}

func name(_ deviceID: AudioObjectID) -> String {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var cfName: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &cfName)
    guard status == noErr, let value = cfName?.takeRetainedValue() else { return "Unknown Audio Device" }
    return value as String
}

func setDefault(_ deviceID: AudioObjectID, selector: AudioObjectPropertySelector, label: String) throws {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var mutableDeviceID = deviceID
    let size = UInt32(MemoryLayout<AudioObjectID>.size)
    let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, size, &mutableDeviceID)
    guard status == noErr else { throw SetOutputError.setFailed(label, status) }
}

do {
    guard CommandLine.arguments.count == 2 else { throw SetOutputError.usage }
    let targetUID = CommandLine.arguments[1]
    guard let device = try allDevices().first(where: { uid($0) == targetUID }) else {
        throw SetOutputError.missingDevice(targetUID)
    }
    try setDefault(device, selector: kAudioHardwarePropertyDefaultOutputDevice, label: "set default output")
    try setDefault(device, selector: kAudioHardwarePropertyDefaultSystemOutputDevice, label: "set default system output")
    print("default output set to \(name(device)) uid=\(targetUID)")
} catch {
    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    fputs("FAIL \(message)\n", stderr)
    exit(1)
}
