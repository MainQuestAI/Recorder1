import Accelerate
import AVFoundation
import AudioToolbox
import Foundation

enum SystemAudioMatrixDiagnostics {
    private struct Report: Encodable {
        var ok: Bool
        var generatedAt: Date
        var bundleID: String
        var executablePath: String
        var appBundlePath: String
        var signing: SigningReport
        var defaultDevices: DefaultDevicesReport
        var probes: [ProbeResult]

        enum CodingKeys: String, CodingKey {
            case ok
            case generatedAt = "generated_at"
            case bundleID = "bundle_id"
            case executablePath = "executable_path"
            case appBundlePath = "app_bundle_path"
            case signing
            case defaultDevices = "default_devices"
            case probes
        }
    }

    private struct SigningReport: Encodable {
        var codesignIdentity: String?
        var isAdHoc: Bool
        var display: String
        var designatedRequirement: String
        var entitlements: String

        enum CodingKeys: String, CodingKey {
            case codesignIdentity = "codesign_identity"
            case isAdHoc = "is_ad_hoc"
            case display
            case designatedRequirement = "designated_requirement"
            case entitlements
        }
    }

    private struct DefaultDevicesReport: Encodable {
        var defaultOutputDevice: SystemAudioDeviceSnapshot?
        var defaultSystemOutputDevice: SystemAudioDeviceSnapshot?
        var areSame: Bool

        enum CodingKeys: String, CodingKey {
            case defaultOutputDevice = "default_output_device"
            case defaultSystemOutputDevice = "default_system_output_device"
            case areSame = "are_same"
        }
    }

    private struct ProbeResult: Encodable {
        var tapKind: String
        var deviceRole: String
        var includeSubDevice: Bool
        var tapPrivate: Bool
        var processRestoreEnabled: Bool?
        var outputDeviceID: UInt32
        var outputDeviceUID: String
        var outputDeviceName: String
        var outputDeviceSampleRate: Double
        var outputDeviceIsRunningSomewhere: Bool
        var aggregateCreated: Bool
        var tapCreated: Bool
        var tapFormat: SystemAudioTapFormatSummary?
        var callbackCount: Int
        var frameCount: Int64
        var inputRMSDB: Double
        var inputPeakDB: Double
        var outputRMSDB: Double
        var outputPeakDB: Double
        var firstNonzeroCallback: Int?
        var ok: Bool
        var error: String?

        enum CodingKeys: String, CodingKey {
            case tapKind = "tap_kind"
            case deviceRole = "device_role"
            case includeSubDevice = "include_subdevice"
            case tapPrivate = "tap_private"
            case processRestoreEnabled = "process_restore_enabled"
            case outputDeviceID = "output_device_id"
            case outputDeviceUID = "output_device_uid"
            case outputDeviceName = "output_device_name"
            case outputDeviceSampleRate = "output_device_sample_rate"
            case outputDeviceIsRunningSomewhere = "output_device_is_running_somewhere"
            case aggregateCreated = "aggregate_created"
            case tapCreated = "tap_created"
            case tapFormat = "tap_format"
            case callbackCount = "callback_count"
            case frameCount = "frame_count"
            case inputRMSDB = "input_rms_db"
            case inputPeakDB = "input_peak_db"
            case outputRMSDB = "output_rms_db"
            case outputPeakDB = "output_peak_db"
            case firstNonzeroCallback = "first_nonzero_callback"
            case ok
            case error
        }
    }

    private enum ProbeTapKind: String {
        case global
        case deviceBound = "device_bound"
        case processAfplay = "process_afplay"
        case processRunningMixdown = "process_running_mixdown"
        case processAllMixdown = "process_all_mixdown"
    }

    private struct ProbeConfig {
        var tapKind: ProbeTapKind
        var deviceRole: SystemAudioDeviceRole
        var includeSubDevice: Bool
        var tapPrivate: Bool
        var processRestoreEnabled: Bool?
    }

    private struct ProbeStats {
        var callbackCount = 0
        var frameCount: Int64 = 0
        var sumSquares = 0.0
        var sampleCount: Int64 = 0
        var peak = 0.0
        var firstNonzeroCallback: Int?

        var rmsDB: Double {
            guard sampleCount > 0 else { return -120 }
            return linearToDB(sqrt(sumSquares / Double(sampleCount)))
        }

        var peakDB: Double {
            linearToDB(peak)
        }
    }

    private final class Probe {
        let config: ProbeConfig
        let duration: TimeInterval

        private var tapID = AudioObjectID(kAudioObjectUnknown)
        private var aggregateID = AudioObjectID(kAudioObjectUnknown)
        private var ioProcID: AudioDeviceIOProcID?
        private var tapFormat: AVAudioFormat?
        private let lock = NSLock()
        private var inputStats = ProbeStats()
        private var outputStats = ProbeStats()
        private var tapCreated = false
        private var aggregateCreated = false
        private var sourceProcess: Process?
        private var sourceToneURL: URL?

        init(config: ProbeConfig, duration: TimeInterval) {
            self.config = config
            self.duration = duration
        }

        func run() -> ProbeResult {
            let deviceID: AudioObjectID
            let snapshot: SystemAudioDeviceSnapshot
            do {
                deviceID = try SystemAudioTap.outputDevice(role: config.deviceRole)
                snapshot = try SystemAudioTap.deviceSnapshot(deviceID: deviceID)
                try start(deviceID: deviceID, outputUID: snapshot.uid)
                let player = config.tapKind == .processAfplay
                    ? nil
                    : try? SystemAudioMatrixDiagnostics.playDiagnosticTone()
                let say = config.tapKind == .processAfplay
                    ? nil
                    : SystemAudioMatrixDiagnostics.playSay()
                Thread.sleep(forTimeInterval: duration)
                if say?.isRunning == true {
                    say?.terminate()
                }
                player?.stop()
                stop()
                return makeResult(snapshot: snapshot, error: nil)
            } catch {
                stop()
                let fallback = (try? SystemAudioTap.outputDevice(role: config.deviceRole))
                    .flatMap { try? SystemAudioTap.deviceSnapshot(deviceID: $0) }
                return makeResult(
                    snapshot: fallback,
                    error: error.localizedDescription
                )
            }
        }

        private func start(deviceID: AudioObjectID, outputUID: String) throws {
            let tapUUID = UUID()
            let desc: CATapDescription
            switch config.tapKind {
            case .global:
                desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
            case .deviceBound:
                desc = CATapDescription(__excludingProcesses: [], andDeviceUID: outputUID, withStream: 0)
            case .processAfplay:
                let source = try SystemAudioMatrixDiagnostics.playAfplayTone(duration: duration + 1.0)
                sourceProcess = source.process
                sourceToneURL = source.toneURL
                usleep(200_000)
                let processObject = try Self.processObjectID(pid: pid_t(source.process.processIdentifier))
                desc = CATapDescription(stereoMixdownOfProcesses: [processObject])
            case .processRunningMixdown, .processAllMixdown:
                let source = try SystemAudioMatrixDiagnostics.playAfplayTone(duration: duration + 1.0)
                sourceProcess = source.process
                sourceToneURL = source.toneURL
                usleep(200_000)
                let processes = try SystemAudioTap.audioProcessObjects(
                    excludingCurrentProcess: false,
                    runningOutputOnly: config.tapKind == .processRunningMixdown
                )
                guard !processes.isEmpty else {
                    throw NSError(domain: "SystemAudioMatrixDiagnostics", code: 3, userInfo: [
                        NSLocalizedDescriptionKey: "No process objects available for \(config.tapKind.rawValue)"
                    ])
                }
                desc = CATapDescription(stereoMixdownOfProcesses: processes)
            }
            desc.uuid = tapUUID
            desc.name = "Meeting Capture Matrix Probe"
            desc.muteBehavior = .unmuted
            desc.isPrivate = config.tapPrivate
            if #available(macOS 26.0, *), let processRestoreEnabled = config.processRestoreEnabled {
                desc.isProcessRestoreEnabled = processRestoreEnabled
            }

            var newTap = AudioObjectID(kAudioObjectUnknown)
            var status = AudioHardwareCreateProcessTap(desc, &newTap)
            guard status == noErr, newTap != kAudioObjectUnknown else {
                throw NSError(domain: "SystemAudioMatrixDiagnostics", code: Int(status), userInfo: [
                    NSLocalizedDescriptionKey: "AudioHardwareCreateProcessTap failed (\(status))"
                ])
            }
            tapID = newTap
            tapCreated = true

            let format = try SystemAudioTap.tapStreamFormat(newTap)
            tapFormat = format

            var aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Meeting Capture Matrix Probe",
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
            if config.includeSubDevice {
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
                throw NSError(domain: "SystemAudioMatrixDiagnostics", code: Int(status), userInfo: [
                    NSLocalizedDescriptionKey: "AudioHardwareCreateAggregateDevice failed (\(status))"
                ])
            }
            aggregateID = newAggregate
            aggregateCreated = true

            var proc: AudioDeviceIOProcID?
            let ioBlock: AudioDeviceIOBlock = { [weak self] _, inputData, _, outputData, _ in
                self?.observe(inputData, outputData: outputData)
            }
            status = AudioDeviceCreateIOProcIDWithBlock(&proc, newAggregate, nil, ioBlock)
            guard status == noErr, let proc else {
                throw NSError(domain: "SystemAudioMatrixDiagnostics", code: Int(status), userInfo: [
                    NSLocalizedDescriptionKey: "AudioDeviceCreateIOProcIDWithBlock failed (\(status))"
                ])
            }
            ioProcID = proc

            status = AudioDeviceStart(newAggregate, proc)
            guard status == noErr else {
                throw NSError(domain: "SystemAudioMatrixDiagnostics", code: Int(status), userInfo: [
                    NSLocalizedDescriptionKey: "AudioDeviceStart failed (\(status))"
                ])
            }
        }

        private func observe(
            _ inputData: UnsafePointer<AudioBufferList>,
            outputData: UnsafePointer<AudioBufferList>
        ) {
            guard let tapFormat else { return }
            lock.lock()
            if let stats = Self.measure(inputData, format: tapFormat) {
                inputStats.callbackCount += 1
                inputStats.frameCount += Int64(stats.frames)
                inputStats.sumSquares += stats.sumSquares
                inputStats.sampleCount += Int64(stats.samples)
                inputStats.peak = max(inputStats.peak, stats.peak)
                if stats.peak > 0.000_03, inputStats.firstNonzeroCallback == nil {
                    inputStats.firstNonzeroCallback = inputStats.callbackCount
                }
            }
            if let stats = Self.measure(outputData, format: tapFormat) {
                outputStats.callbackCount += 1
                outputStats.frameCount += Int64(stats.frames)
                outputStats.sumSquares += stats.sumSquares
                outputStats.sampleCount += Int64(stats.samples)
                outputStats.peak = max(outputStats.peak, stats.peak)
                if stats.peak > 0.000_03, outputStats.firstNonzeroCallback == nil {
                    outputStats.firstNonzeroCallback = outputStats.callbackCount
                }
            }
            lock.unlock()
        }

        private static func measure(
            _ audioBufferList: UnsafePointer<AudioBufferList>,
            format: AVAudioFormat
        ) -> (frames: Int, samples: Int, sumSquares: Double, peak: Double)? {
            guard format.commonFormat == .pcmFormatFloat32 else { return nil }
            let channelCount = Int(format.channelCount)
            guard channelCount > 0 else { return nil }
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

            var sumSquares = 0.0
            var peak = 0.0
            if format.isInterleaved {
                for index in 0..<(frames * channelCount) {
                    let value = Double(firstData[index])
                    sumSquares += value * value
                    peak = max(peak, abs(value))
                }
                return (frames, frames * channelCount, sumSquares, peak)
            }

            let availableBuffers = min(channelCount, buffers.count)
            for channel in 0..<availableBuffers {
                guard let data = buffers[channel].mData?.assumingMemoryBound(to: Float.self) else { continue }
                for frame in 0..<frames {
                    let value = Double(data[frame])
                    sumSquares += value * value
                    peak = max(peak, abs(value))
                }
            }
            return (frames, frames * availableBuffers, sumSquares, peak)
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
            if let sourceProcess, sourceProcess.isRunning {
                sourceProcess.terminate()
            }
            sourceProcess = nil
            if let sourceToneURL {
                try? FileManager.default.removeItem(at: sourceToneURL.deletingLastPathComponent())
            }
            sourceToneURL = nil
        }

        private func makeResult(snapshot: SystemAudioDeviceSnapshot?, error: String?) -> ProbeResult {
            lock.lock()
            let input = inputStats
            let output = outputStats
            lock.unlock()
            let ok = input.rmsDB > -80 || input.peakDB > -60
            return ProbeResult(
                tapKind: config.tapKind.rawValue,
                deviceRole: config.deviceRole.rawValue,
                includeSubDevice: config.includeSubDevice,
                tapPrivate: config.tapPrivate,
                processRestoreEnabled: config.processRestoreEnabled,
                outputDeviceID: snapshot?.id ?? 0,
                outputDeviceUID: snapshot?.uid ?? "",
                outputDeviceName: snapshot?.name ?? "",
                outputDeviceSampleRate: snapshot?.sampleRate ?? 0,
                outputDeviceIsRunningSomewhere: snapshot?.isRunningSomewhere ?? false,
                aggregateCreated: aggregateCreated,
                tapCreated: tapCreated,
                tapFormat: tapFormat.map(SystemAudioTap.tapFormatSummary),
                callbackCount: input.callbackCount,
                frameCount: input.frameCount,
                inputRMSDB: input.rmsDB,
                inputPeakDB: input.peakDB,
                outputRMSDB: output.rmsDB,
                outputPeakDB: output.peakDB,
                firstNonzeroCallback: input.firstNonzeroCallback,
                ok: ok,
                error: error
            )
        }

        private static func processObjectID(pid: pid_t) throws -> AudioObjectID {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var sourcePID = pid
            var processObject = AudioObjectID(kAudioObjectUnknown)
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            let qualifierSize = UInt32(MemoryLayout<pid_t>.size)
            let status = withUnsafePointer(to: &sourcePID) { pidPointer in
                AudioObjectGetPropertyData(
                    AudioObjectID(kAudioObjectSystemObject),
                    &address,
                    qualifierSize,
                    pidPointer,
                    &size,
                    &processObject
                )
            }
            guard status == noErr, processObject != kAudioObjectUnknown else {
                throw NSError(domain: "SystemAudioMatrixDiagnostics", code: Int(status), userInfo: [
                    NSLocalizedDescriptionKey: "Translate PID \(pid) to audio process failed (\(status))"
                ])
            }
            return processObject
        }
    }

    static func runAndExit() -> Never {
        let report = run()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(report),
           let text = String(data: data, encoding: .utf8) {
            print(text)
            if let outputURL = outputURLFromArguments() {
                try? text.write(to: outputURL, atomically: true, encoding: .utf8)
            }
        }
        exit(report.ok ? 0 : 1)
    }

    private static func run() -> Report {
        let baseConfigs = [
            ProbeConfig(tapKind: .global, deviceRole: .defaultOutput, includeSubDevice: true, tapPrivate: true, processRestoreEnabled: true),
            ProbeConfig(tapKind: .deviceBound, deviceRole: .defaultOutput, includeSubDevice: true, tapPrivate: true, processRestoreEnabled: true),
            ProbeConfig(tapKind: .global, deviceRole: .defaultSystemOutput, includeSubDevice: true, tapPrivate: true, processRestoreEnabled: true),
            ProbeConfig(tapKind: .deviceBound, deviceRole: .defaultSystemOutput, includeSubDevice: true, tapPrivate: true, processRestoreEnabled: true),
            ProbeConfig(tapKind: .global, deviceRole: .defaultOutput, includeSubDevice: false, tapPrivate: true, processRestoreEnabled: true),
            ProbeConfig(tapKind: .deviceBound, deviceRole: .defaultOutput, includeSubDevice: false, tapPrivate: true, processRestoreEnabled: true),
            ProbeConfig(tapKind: .global, deviceRole: .defaultSystemOutput, includeSubDevice: false, tapPrivate: true, processRestoreEnabled: true),
            ProbeConfig(tapKind: .deviceBound, deviceRole: .defaultSystemOutput, includeSubDevice: false, tapPrivate: true, processRestoreEnabled: true),
        ]
        var configs = baseConfigs
        configs.append(contentsOf: [
            ProbeConfig(
                tapKind: .global,
                deviceRole: .defaultOutput,
                includeSubDevice: true,
                tapPrivate: true,
                processRestoreEnabled: false
            ),
            ProbeConfig(
                tapKind: .deviceBound,
                deviceRole: .defaultOutput,
                includeSubDevice: true,
                tapPrivate: true,
                processRestoreEnabled: false
            ),
            ProbeConfig(
                tapKind: .global,
                deviceRole: .defaultOutput,
                includeSubDevice: true,
                tapPrivate: false,
                processRestoreEnabled: true
            ),
            ProbeConfig(
                tapKind: .deviceBound,
                deviceRole: .defaultOutput,
                includeSubDevice: true,
                tapPrivate: false,
                processRestoreEnabled: true
            ),
            ProbeConfig(
                tapKind: .processAfplay,
                deviceRole: .defaultOutput,
                includeSubDevice: true,
                tapPrivate: true,
                processRestoreEnabled: true
            ),
            ProbeConfig(
                tapKind: .processAfplay,
                deviceRole: .defaultOutput,
                includeSubDevice: true,
                tapPrivate: false,
                processRestoreEnabled: true
            ),
            ProbeConfig(
                tapKind: .processRunningMixdown,
                deviceRole: .defaultOutput,
                includeSubDevice: true,
                tapPrivate: true,
                processRestoreEnabled: true
            ),
            ProbeConfig(
                tapKind: .processAllMixdown,
                deviceRole: .defaultOutput,
                includeSubDevice: true,
                tapPrivate: true,
                processRestoreEnabled: true
            ),
        ])

        let probes = configs.map { config in
            let probe = Probe(config: config, duration: 2.5)
            return probe.run()
        }
        let defaultDevices = makeDefaultDevicesReport()
        let ok = probes.contains { $0.deviceRole == SystemAudioDeviceRole.defaultOutput.rawValue && $0.ok }
        return Report(
            ok: ok,
            generatedAt: Date(),
            bundleID: Bundle.main.bundleIdentifier ?? "",
            executablePath: Bundle.main.executableURL?.path ?? CommandLine.arguments.first ?? "",
            appBundlePath: Bundle.main.bundleURL.path,
            signing: makeSigningReport(),
            defaultDevices: defaultDevices,
            probes: probes
        )
    }

    private static func makeDefaultDevicesReport() -> DefaultDevicesReport {
        let defaultOutput = (try? SystemAudioTap.outputDevice(role: .defaultOutput))
            .flatMap { try? SystemAudioTap.deviceSnapshot(deviceID: $0) }
        let defaultSystem = (try? SystemAudioTap.outputDevice(role: .defaultSystemOutput))
            .flatMap { try? SystemAudioTap.deviceSnapshot(deviceID: $0) }
        return DefaultDevicesReport(
            defaultOutputDevice: defaultOutput,
            defaultSystemOutputDevice: defaultSystem,
            areSame: defaultOutput?.uid == defaultSystem?.uid && defaultOutput != nil
        )
    }

    private static func makeSigningReport() -> SigningReport {
        let bundlePath = Bundle.main.bundleURL.path
        let display = runProcess("/usr/bin/codesign", ["-dv", "--verbose=4", bundlePath])
        let requirement = runProcess("/usr/bin/codesign", ["-dr", "-", bundlePath])
        let entitlements = runProcess("/usr/bin/codesign", ["--display", "--entitlements", ":-", bundlePath])
        let authority = display
            .split(separator: "\n")
            .first(where: { $0.contains("Authority=") })
            .map { String($0).replacingOccurrences(of: "Authority=", with: "") }
        let isAdHoc = display.contains("Signature=adhoc") || display.contains("(adhoc")
        return SigningReport(
            codesignIdentity: authority,
            isAdHoc: isAdHoc,
            display: display,
            designatedRequirement: requirement,
            entitlements: entitlements
        )
    }

    private static func runProcess(_ executable: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
            process.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        } catch {
            return error.localizedDescription
        }
    }

    private static func outputURLFromArguments() -> URL? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--diagnose-output"),
              arguments.indices.contains(index + 1) else {
            return nil
        }
        return URL(fileURLWithPath: arguments[index + 1])
    }

    private static func playSay() -> Process? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = [
            "Meeting Capture system audio matrix probe. This sentence should be captured."
        ]
        try? process.run()
        return process
    }

    private static func playDiagnosticTone() throws -> AVAudioPlayer {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingCaptureMatrixTone-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let toneURL = folder.appendingPathComponent("tone.wav")
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(48_000 * 2)
        ), let data = buffer.floatChannelData?[0] else {
            throw NSError(domain: "SystemAudioMatrixDiagnostics", code: 1)
        }

        buffer.frameLength = buffer.frameCapacity
        for frame in 0..<Int(buffer.frameLength) {
            data[frame] = Float(sin(Double(frame) / 48_000.0 * 660.0 * 2.0 * Double.pi) * 0.25)
        }
        let file = try AVAudioFile(
            forWriting: toneURL,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsBigEndianKey: false
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try file.write(from: buffer)
        let player = try AVAudioPlayer(contentsOf: toneURL)
        player.volume = 1.0
        player.prepareToPlay()
        player.play()
        return player
    }

    private static func playAfplayTone(duration: TimeInterval) throws -> (process: Process, toneURL: URL) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingCaptureAfplayTone-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let toneURL = folder.appendingPathComponent("tone.wav")
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(48_000 * max(1, Int(ceil(duration))))
        ), let data = buffer.floatChannelData?[0] else {
            throw NSError(domain: "SystemAudioMatrixDiagnostics", code: 2)
        }

        buffer.frameLength = buffer.frameCapacity
        for frame in 0..<Int(buffer.frameLength) {
            data[frame] = Float(sin(Double(frame) / 48_000.0 * 550.0 * 2.0 * Double.pi) * 0.25)
        }
        let file = try AVAudioFile(
            forWriting: toneURL,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsBigEndianKey: false
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try file.write(from: buffer)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        process.arguments = [toneURL.path]
        try process.run()
        return (process, toneURL)
    }

    private static func linearToDB(_ value: Double) -> Double {
        guard value > 0 else { return -120 }
        return max(-120, 20 * log10(value))
    }
}
