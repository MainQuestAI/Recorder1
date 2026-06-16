import AVFoundation
import AudioToolbox
import Foundation

enum SystemAudioDiagnostics {
    private struct Result: Encodable {
        var ok: Bool
        var desktopURL: String
        var frameCount: Int64
        var sampleRate: Double
        var rmsDB: Double
        var peakDB: Double
        var error: String?
    }

    static func runAndExit() -> Never {
        let result: Result
        do {
            result = try run()
        } catch {
            result = Result(
                ok: false,
                desktopURL: "",
                frameCount: 0,
                sampleRate: 0,
                rmsDB: -120,
                peakDB: -120,
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
            .appendingPathComponent("MeetingCaptureSystemAudio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let desktopURL = folder.appendingPathComponent("desktop.caf")

        let tap = SystemAudioTap()
        try tap.start(writingTo: desktopURL)

        usleep(500_000)
        let player = try? playDiagnosticTone(in: folder)
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = [
            "Meeting Capture system audio diagnostic. This sentence should be captured by the desktop channel."
        ]
        try? say.run()
        Thread.sleep(forTimeInterval: 5.0)
        if say.isRunning {
            say.terminate()
        }
        player?.stop()

        let capture = tap.stop()
        let levels = try analyzeMonoAudio(url: desktopURL)
        return Result(
            ok: levels.rmsDB > -80 || levels.peakDB > -60,
            desktopURL: desktopURL.path,
            frameCount: Int64(capture.frameCount),
            sampleRate: capture.sampleRate,
            rmsDB: levels.rmsDB,
            peakDB: levels.peakDB,
            error: nil
        )
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
            frameCapacity: AVAudioFrameCount(48_000 * 3)
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
}
