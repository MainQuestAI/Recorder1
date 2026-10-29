import AVFoundation
import AudioToolbox
import CoreAudio
import os
import Foundation

enum SystemAudioDiagnostics {
    @MainActor
    static func runUploadGateAndExit() -> Never {
        guard let index = CommandLine.arguments.firstIndex(of: "--diagnose-folder"),
              CommandLine.arguments.indices.contains(index + 1) else { exit(2) }
        let folder = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
        Task { @MainActor in
            let model = RecorderModel()
            model.uploadExisting(RecordingEntry(folderURL: folder, title: "Integrity gate verification", date: Date(),
                audioURL: folder.appendingPathComponent("audio.m4a"), transcriptURL: nil, minuteURL: nil, uploadStatus: "failed"))
            for _ in 0..<300 {
                if case .needsConfirmation = model.uploadState {
                    print("PASS library upload is blocked by recording integrity before any CLI upload")
                    exit(0)
                }
                if case .failed(let error) = model.uploadState { fputs("FAIL \(error)\n", stderr); exit(1) }
                if case .uploaded = model.uploadState { fputs("FAIL integrity gate was bypassed\n", stderr); exit(1) }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            fputs("FAIL upload gate timed out\n", stderr)
            exit(1)
        }
        dispatchMain()
    }

    private struct Result: Encodable {
        var ok: Bool
        var desktopURL: String
        var micURL: String?
        var audioURL: String?
        var frameCount: Int64
        var sampleRate: Double
        var rmsDB: Double
        var peakDB: Double
        var audioLeftRMSDB: Double?
        var audioLeftPeakDB: Double?
        var audioRightRMSDB: Double?
        var audioRightPeakDB: Double?
        var systemAudioConfig: SystemAudioCaptureConfig?
        var systemAudioFallbackEvents: [String]
        var systemAudioCaptureFailed: Bool?
        var systemAudioLastFailureReason: String?
        var error: String?
        var audioQuality: AudioQualityReport? = nil
        var integrity: CaptureIntegrity? = nil
        var microphoneCapture: MicrophoneCaptureMetadata? = nil
        var microphoneFailure: String? = nil
        var microphoneFrameCount: Int64? = nil
        var microphoneSampleRate: Double? = nil
        var routeChanges: [SystemAudioRouteChangeEvent]? = nil

        enum CodingKeys: String, CodingKey {
            case ok
            case desktopURL = "desktop_url"
            case micURL = "mic_url"
            case audioURL = "audio_url"
            case frameCount = "frame_count"
            case sampleRate = "sample_rate"
            case rmsDB = "rms_db"
            case peakDB = "peak_db"
            case audioLeftRMSDB = "audio_left_rms_db"
            case audioLeftPeakDB = "audio_left_peak_db"
            case audioRightRMSDB = "audio_right_rms_db"
            case audioRightPeakDB = "audio_right_peak_db"
            case systemAudioConfig = "system_audio_config"
            case systemAudioFallbackEvents = "system_audio_fallback_events"
            case systemAudioCaptureFailed = "system_audio_capture_failed"
            case systemAudioLastFailureReason = "system_audio_last_failure_reason"
            case error
            case audioQuality = "audio_quality"
            case integrity
            case microphoneCapture = "microphone_capture"
            case microphoneFailure = "microphone_failure"
            case microphoneFrameCount = "microphone_frame_count"
            case microphoneSampleRate = "microphone_sample_rate"
            case routeChanges = "route_changes"
        }
    }

    static func runAndExit() -> Never {
        runAndExit(result: {
            try run()
        })
    }

    static func runRecordingAcceptanceAndExit() -> Never {
        runAndExit(result: {
            try runRecordingAcceptance()
        })
    }

    private static func runAndExit(result makeResult: () throws -> Result) -> Never {
        let result: Result
        do {
            result = try makeResult()
        } catch {
            result = Result(
                ok: false,
                desktopURL: "",
                micURL: nil,
                audioURL: nil,
                frameCount: 0,
                sampleRate: 0,
                rmsDB: -120,
                peakDB: -120,
                audioLeftRMSDB: nil,
                audioLeftPeakDB: nil,
                audioRightRMSDB: nil,
                audioRightPeakDB: nil,
                systemAudioConfig: nil,
                systemAudioFallbackEvents: [],
                systemAudioCaptureFailed: nil,
                systemAudioLastFailureReason: nil,
                error: error.localizedDescription
            )
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(result),
           let text = String(data: data, encoding: .utf8) {
            print(text)
            if let outputURL = outputURLFromArguments() {
                try? text.write(to: outputURL, atomically: true, encoding: .utf8)
            }
        }
        exit(result.ok ? 0 : 1)
    }

    private static func outputURLFromArguments() -> URL? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--diagnose-output"),
              arguments.indices.contains(index + 1) else {
            return nil
        }
        return URL(fileURLWithPath: arguments[index + 1])
    }

    private static func run() throws -> Result {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Recorder1SystemAudio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let desktopURL = folder.appendingPathComponent("desktop.caf")

        let tap = SystemAudioTap()
        try tap.start(writingTo: desktopURL)

        usleep(500_000)
        let player = try? playDiagnosticTone(in: folder)
        let afplay = try? playAfplayTone(in: folder)
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = [
            "Recorder1 system audio diagnostic. This sentence should be captured by the desktop channel."
        ]
        try? say.run()
        Thread.sleep(forTimeInterval: 9.0)
        if say.isRunning {
            say.terminate()
        }
        if afplay?.isRunning == true {
            afplay?.terminate()
        }
        player?.stop()

        let capture = tap.stop()
        let levels = try analyzeMonoAudio(url: desktopURL)
        return Result(
            ok: levels.rmsDB > -80 || levels.peakDB > -60,
            desktopURL: desktopURL.path,
            micURL: nil,
            audioURL: nil,
            frameCount: Int64(capture.frameCount),
            sampleRate: capture.sampleRate,
            rmsDB: levels.rmsDB,
            peakDB: levels.peakDB,
            audioLeftRMSDB: nil,
            audioLeftPeakDB: nil,
            audioRightRMSDB: nil,
            audioRightPeakDB: nil,
            systemAudioConfig: capture.systemAudio?.config,
            systemAudioFallbackEvents: capture.systemAudio?.fallbackEvents ?? [],
            systemAudioCaptureFailed: capture.systemAudio?.systemAudioCaptureFailed,
            systemAudioLastFailureReason: capture.systemAudio?.lastFailureReason,
            error: nil
        )
    }

    private static func runRecordingAcceptance() throws -> Result {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Recorder1AudioAcceptance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let desktopURL = folder.appendingPathComponent("desktop.caf")
        let micURL = folder.appendingPathComponent("mic.caf")
        let audioURL = folder.appendingPathComponent("audio.m4a")

        let tap = SystemAudioTap()
        let mic = MicCapture()
        let routes = OSAllocatedUnfairLock<[SystemAudioRouteChangeEvent]>(initialState: [])
        tap.onRouteChanged = { event in routes.withLock { $0.append(event) } }
        mic.onEvent = { event in fputs("Microphone: \(event)\n", stderr) }
        try tap.start(writingTo: desktopURL)
        let args = CommandLine.arguments
        let inputIndex = args.firstIndex(of: "--diagnose-input-uid")
        let inputUID = inputIndex.flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        do { try mic.start(writingTo: micURL, preferredInputDeviceUID: inputUID) }
        catch { _ = tap.stop(); throw error }

        let continuity = CommandLine.arguments.contains("--diagnose-continuity")
        let started = Date()
        if let index = args.firstIndex(of: "--diagnose-switch-output-uid"), args.indices.contains(index + 1) {
            let originalOutput = try SystemAudioTap.outputDevice(role: .defaultOutput)
            let originalSystem = try SystemAudioTap.outputDevice(role: .defaultSystemOutput)
            defer {
                do { try setOutput(originalOutput, system: false); try setOutput(originalSystem, system: true) }
                catch { fputs("FAIL restoring output: \(error)\n", stderr) }
            }
            do {
                Thread.sleep(forTimeInterval: 5)
                let target = try outputID(uid: args[index + 1])
                try setOutput(target, system: false); try setOutput(target, system: true)
                Thread.sleep(forTimeInterval: 8)
                try setOutput(originalOutput, system: false); try setOutput(originalSystem, system: true)
                Thread.sleep(forTimeInterval: 3)
            } catch { _ = tap.stop(); _ = mic.stop(); throw error }
        }
        if continuity { Thread.sleep(forTimeInterval: 12) }
        usleep(500_000)
        let player = try? playDiagnosticTone(in: folder)
        let afplay = try? playAfplayTone(in: folder)
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = [
            "Recorder1 acceptance recording. This sentence should appear on the desktop channel."
        ]
        try? say.run()
        Thread.sleep(forTimeInterval: 9.0)
        if say.isRunning {
            say.terminate()
        }
        if afplay?.isRunning == true {
            afplay?.terminate()
        }
        player?.stop()

        if continuity {
            let arguments = CommandLine.arguments
            let durationIndex = arguments.firstIndex(of: "--diagnose-duration")
            let duration = durationIndex.flatMap { index in
                arguments.indices.contains(index + 1) ? Double(arguments[index + 1]) : nil
            } ?? 90
            tap.setPaused(true)
            mic.setPaused(true)
            Thread.sleep(forTimeInterval: 4)
            tap.setPaused(false)
            mic.setPaused(false)
            while Date().timeIntervalSince(started) < max(40, duration) {
                // Each cycle opens a NEW audio process after silence, exercising dynamic process
                // coverage rather than only capturing sources that existed when recording began.
                Thread.sleep(forTimeInterval: 6)
                let latePlayer = try playAfplayTone(in: folder)
                Thread.sleep(forTimeInterval: 3)
                if latePlayer.isRunning { latePlayer.terminate(); latePlayer.waitUntilExit() }
            }
        }
        let desktopCapture = tap.stop()
        let micCapture = mic.stop()
        try StereoMixer.mix(
            desktopURL: desktopURL,
            micURL: micURL,
            desktopResult: desktopCapture,
            micResult: micCapture,
            outputURL: audioURL
        )

        let desktopLevels = try analyzeMonoAudio(url: desktopURL)
        let audioQuality = try AudioQualityAnalyzer.analyze(audioURL: audioURL)
        let integrity = RecordingAcceptance.evaluate(quality: audioQuality, capture: desktopCapture.systemAudio,
                                                      desktop: desktopCapture, microphone: micCapture)
        let ok = !integrity.requiresUploadConfirmation

        return Result(
            ok: ok,
            desktopURL: desktopURL.path,
            micURL: micURL.path,
            audioURL: audioURL.path,
            frameCount: Int64(desktopCapture.frameCount),
            sampleRate: desktopCapture.sampleRate,
            rmsDB: desktopLevels.rmsDB,
            peakDB: desktopLevels.peakDB,
            audioLeftRMSDB: audioQuality.leftDesktopRMSDB,
            audioLeftPeakDB: audioQuality.leftDesktopPeakDB,
            audioRightRMSDB: audioQuality.rightMicRMSDB,
            audioRightPeakDB: audioQuality.rightMicPeakDB,
            systemAudioConfig: desktopCapture.systemAudio?.config,
            systemAudioFallbackEvents: desktopCapture.systemAudio?.fallbackEvents ?? [],
            systemAudioCaptureFailed: desktopCapture.systemAudio?.systemAudioCaptureFailed,
            systemAudioLastFailureReason: desktopCapture.systemAudio?.lastFailureReason,
            error: nil,
            audioQuality: audioQuality,
            integrity: integrity,
            microphoneCapture: micCapture.microphone,
            microphoneFailure: micCapture.failureReason,
            microphoneFrameCount: Int64(micCapture.frameCount),
            microphoneSampleRate: micCapture.sampleRate,
            routeChanges: routes.withLock { $0 }
        )
    }

    private static func setOutput(_ device: AudioObjectID, system: Bool) throws {
        var address = AudioObjectPropertyAddress(mSelector: system ? kAudioHardwarePropertyDefaultSystemOutputDevice : kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value = device
        let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            UInt32(MemoryLayout<AudioObjectID>.size), &value)
        guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    private static func outputID(uid: String) throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
        guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        var devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices)
        guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        for device in devices {
            var key = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var value: Unmanaged<CFString>?
            var valueSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            if AudioObjectGetPropertyData(device, &key, 0, nil, &valueSize, &value) == noErr,
               let value = value?.takeRetainedValue(), value as String == uid { return device }
        }
        throw NSError(domain: "Diagnostics", code: 1, userInfo: [NSLocalizedDescriptionKey: "Output device not available: \(uid)"])
    }

    private static func analyzeMonoAudio(url: URL) throws -> (rmsDB: Double, peakDB: Double) {
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(min(file.length, 48_000))
        ) else {
            return (-120, -120)
        }

        var sumSquares = 0.0
        var sampleCount = 0
        var peak = 0.0

        while file.framePosition < file.length {
            let remaining = file.length - file.framePosition
            buffer.frameLength = 0
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(Int64(buffer.frameCapacity), remaining)))
            guard let channelData = buffer.floatChannelData else { continue }

            let channels = Int(buffer.format.channelCount)
            let frames = Int(buffer.frameLength)
            guard frames > 0, channels > 0 else { continue }

            for channel in 0..<channels {
                let data = channelData[channel]
                for frame in 0..<frames {
                    let value = Double(data[frame])
                    sumSquares += value * value
                    peak = max(peak, abs(value))
                    sampleCount += 1
                }
            }
        }

        let rms = sampleCount > 0 ? sqrt(sumSquares / Double(sampleCount)) : 0
        return (db(rms), db(peak))
    }

    private static func db(_ value: Double) -> Double {
        guard value > 0 else { return -120 }
        return max(-120, 20 * log10(value))
    }

    private static func playDiagnosticTone(in folder: URL) throws -> AVAudioPlayer {
        let toneURL = folder.appendingPathComponent("tone.wav")
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(48_000 * 10)
        ), let data = buffer.floatChannelData?[0] else {
            throw NSError(domain: "SystemAudioDiagnostics", code: 1)
        }

        buffer.frameLength = buffer.frameCapacity
        for frame in 0..<Int(buffer.frameLength) {
            data[frame] = Float(sin(Double(frame) / 48_000.0 * 440.0 * 2.0 * Double.pi) * 0.25)
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

    private static func playAfplayTone(in folder: URL) throws -> Process {
        let toneURL = folder.appendingPathComponent("afplay-tone.wav")
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(48_000 * 12)
        ), let data = buffer.floatChannelData?[0] else {
            throw NSError(domain: "SystemAudioDiagnostics", code: 2)
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
        return process
    }
}
