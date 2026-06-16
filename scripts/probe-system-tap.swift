import Accelerate
import AVFoundation
import CoreAudio
import Foundation

enum ProbeError: LocalizedError {
    case coreAudio(String, OSStatus)
    case invalidFormat
    case missingOutputDevice

    var errorDescription: String? {
        switch self {
        case .coreAudio(let op, let status):
            return "\(op) failed with OSStatus \(status)"
        case .invalidFormat:
            return "tap returned an invalid format"
        case .missingOutputDevice:
            return "could not resolve output device"
        }
    }
}

final class TapProbe {
    enum DeviceKind: String {
        case output
        case system
    }

    enum TapKind: String {
        case global
        case device
    }

    var deviceKind: DeviceKind = .output
    var tapKind: TapKind = .global
    var includeSubDevice = true
    var duration: TimeInterval = 6

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var tapFormat: AVAudioFormat?

    private let lock = NSLock()
    private var inputCallbacks = 0
    private var outputCallbacks = 0
    private var inputMaxRMS: Float = 0
    private var outputMaxRMS: Float = 0
    private var inputFirstNonZero: Int?
    private var outputFirstNonZero: Int?

    func run() throws {
        try start()
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = [
            "Meeting Capture Core Audio tap probe. This sentence should produce non zero system output samples."
        ]
        try? say.run()
        Thread.sleep(forTimeInterval: duration)
        stop()
        if say.isRunning { say.terminate() }

        print("mode: tap=\(tapKind.rawValue) device=\(deviceKind.rawValue) include_subdevice=\(includeSubDevice)")
        if let tapFormat {
            print("tap_format: \(tapFormat.channelCount)ch \(Int(tapFormat.sampleRate))Hz interleaved=\(tapFormat.isInterleaved)")
        }
        print("input_callbacks: \(inputCallbacks)")
        print("input_max_rms_db: \(db(inputMaxRMS))")
        print("input_first_nonzero_callback: \(inputFirstNonZero.map(String.init) ?? "none")")
        print("output_callbacks: \(outputCallbacks)")
        print("output_max_rms_db: \(db(outputMaxRMS))")
        print("output_first_nonzero_callback: \(outputFirstNonZero.map(String.init) ?? "none")")
    }

    private func start() throws {
        let outputDevice = try Self.outputDevice(kind: deviceKind)
        let outputUID = try Self.deviceUID(outputDevice)
        let tapUUID = UUID()

        let desc: CATapDescription
        switch tapKind {
        case .global:
            desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        case .device:
            desc = CATapDescription(__excludingProcesses: [], andDeviceUID: outputUID, withStream: 0)
        }
        desc.uuid = tapUUID
        desc.name = "Meeting Capture Tap Probe"
        desc.muteBehavior = .unmuted
        desc.isPrivate = true
        if #available(macOS 26.0, *) {
            desc.isProcessRestoreEnabled = true
        }

        var newTap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(desc, &newTap)
        guard status == noErr, newTap != kAudioObjectUnknown else {
            throw ProbeError.coreAudio("AudioHardwareCreateProcessTap", status)
        }
        tapID = newTap

        let format = try Self.tapFormat(newTap)
        tapFormat = format

        var aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Meeting Capture Tap Probe",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUUID.uuidString,
                    kAudioSubTapDriftCompensationKey: 1,
                    kAudioSubTapDriftCompensationQualityKey: 0x60
                ]
            ]
        ]
        if includeSubDevice {
            aggregate[kAudioAggregateDeviceSubDeviceListKey] = [
                [
                    kAudioSubDeviceUIDKey: outputUID,
                    kAudioSubDeviceDriftCompensationKey: 0
                ]
            ]
        }

        var newAggregate = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &newAggregate)
        guard status == noErr, newAggregate != kAudioObjectUnknown else {
            throw ProbeError.coreAudio("AudioHardwareCreateAggregateDevice", status)
        }
        aggregateID = newAggregate

        var proc: AudioDeviceIOProcID?
        let ioBlock: AudioDeviceIOBlock = { [weak self] _, inputData, _, outputData, _ in
            self?.observe(inputData, outputData: outputData)
        }
        status = AudioDeviceCreateIOProcIDWithBlock(&proc, newAggregate, nil, ioBlock)
        guard status == noErr, let proc else {
            throw ProbeError.coreAudio("AudioDeviceCreateIOProcIDWithBlock", status)
        }
        ioProcID = proc

        status = AudioDeviceStart(newAggregate, proc)
        guard status == noErr else {
            throw ProbeError.coreAudio("AudioDeviceStart", status)
        }
    }

    private func stop() {
        if let ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
    }

    private func observe(
        _ inputData: UnsafePointer<AudioBufferList>,
        outputData: UnsafePointer<AudioBufferList>
    ) {
        guard let format = tapFormat else { return }
        if let rms = Self.rms(inputData, format: format) {
            lock.lock()
            inputCallbacks += 1
            inputMaxRMS = max(inputMaxRMS, rms)
            if rms > 0.000_03, inputFirstNonZero == nil {
                inputFirstNonZero = inputCallbacks
            }
            lock.unlock()
        }
        if let rms = Self.rms(outputData, format: format) {
            lock.lock()
            outputCallbacks += 1
            outputMaxRMS = max(outputMaxRMS, rms)
            if rms > 0.000_03, outputFirstNonZero == nil {
                outputFirstNonZero = outputCallbacks
            }
            lock.unlock()
        }
    }

    private static func rms(
        _ audioBufferList: UnsafePointer<AudioBufferList>,
        format: AVAudioFormat
    ) -> Float? {
        guard format.commonFormat == .pcmFormatFloat32 else {
            return nil
        }
        let channelCount = Int(format.channelCount)
        guard channelCount > 0 else {
            return nil
        }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: audioBufferList))
        guard let firstBuffer = buffers.first,
              let firstData = firstBuffer.mData?.assumingMemoryBound(to: Float.self) else {
            return nil
        }
        let frames: Int
        if format.isInterleaved {
            frames = Int(firstBuffer.mDataByteSize) / (MemoryLayout<Float>.stride * channelCount)
        } else {
            frames = Int(firstBuffer.mDataByteSize) / MemoryLayout<Float>.stride
        }
        guard frames > 0 else { return nil }
        var rms: Float = 0
        vDSP_rmsqv(firstData, vDSP_Stride(format.isInterleaved ? channelCount : 1), &rms, vDSP_Length(frames))
        return rms
    }

    private static func outputDevice(kind: DeviceKind) throws -> AudioObjectID {
        let selector: AudioObjectPropertySelector = kind == .output
            ? kAudioHardwarePropertyDefaultOutputDevice
            : kAudioHardwarePropertyDefaultSystemOutputDevice
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else {
            throw ProbeError.missingOutputDevice
        }
        return deviceID
    }

    private static func deviceUID(_ deviceID: AudioObjectID) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid)
        guard status == noErr, let value = uid?.takeRetainedValue() else {
            throw ProbeError.coreAudio("kAudioDevicePropertyDeviceUID", status)
        }
        return value as String
    }

    private static func tapFormat(_ tapID: AudioObjectID) throws -> AVAudioFormat {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        guard status == noErr, let format = AVAudioFormat(streamDescription: &asbd) else {
            throw ProbeError.invalidFormat
        }
        return format
    }

    private func db(_ value: Float) -> String {
        let db = value > 0 ? max(-120, 20 * log10(value)) : -120
        return String(format: "%.1f", db)
    }
}

func parseProbe() throws -> TapProbe {
    let probe = TapProbe()
    var args = Array(CommandLine.arguments.dropFirst())
    while !args.isEmpty {
        let arg = args.removeFirst()
        switch arg {
        case "--device":
            let value = args.removeFirst()
            probe.deviceKind = TapProbe.DeviceKind(rawValue: value) ?? .output
        case "--tap":
            let value = args.removeFirst()
            probe.tapKind = TapProbe.TapKind(rawValue: value) ?? .global
        case "--no-subdevice":
            probe.includeSubDevice = false
        case "--duration":
            probe.duration = TimeInterval(Double(args.removeFirst()) ?? 6)
        default:
            break
        }
    }
    return probe
}

do {
    try parseProbe().run()
} catch {
    fputs("FAIL \(error.localizedDescription)\n", stderr)
    exit(1)
}
