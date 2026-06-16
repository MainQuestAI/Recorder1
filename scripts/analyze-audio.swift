import AVFoundation
import Foundation

struct Options {
    var audioPath: String?
    var minDurationSeconds: Double = 1
    var requireActiveChannels = true
    var activeThresholdDB: Double = -60
}

enum AnalyzeError: LocalizedError {
    case usage
    case missingFile(String)
    case cannotOpen(String)
    case invalidChannelCount(Int)
    case tooShort(actual: Double, expected: Double)
    case channelSilent(channel: String, db: Double, threshold: Double)
    case unreadablePCM

    var errorDescription: String? {
        switch self {
        case .usage:
            return """
            usage: swift scripts/analyze-audio.swift <audio.m4a> [--min-duration seconds] [--threshold-db db] [--allow-silent-channel]
            """
        case .missingFile(let path):
            return "audio file not found: \(path)"
        case .cannotOpen(let path):
            return "could not open audio file: \(path)"
        case .invalidChannelCount(let count):
            return "expected stereo audio, got \(count) channel(s)"
        case .tooShort(let actual, let expected):
            return String(format: "duration %.3fs is shorter than required %.3fs", actual, expected)
        case .channelSilent(let channel, let db, let threshold):
            return String(format: "%@ channel RMS %.1f dB is below %.1f dB", channel, db, threshold)
        case .unreadablePCM:
            return "could not read PCM samples from audio file"
        }
    }
}

struct ChannelStats {
    var sumSquares: Double = 0
    var peak: Double = 0
    var sampleCount: Int64 = 0

    var rms: Double {
        guard sampleCount > 0 else { return 0 }
        return sqrt(sumSquares / Double(sampleCount))
    }

    var rmsDB: Double {
        linearToDB(rms)
    }

    var peakDB: Double {
        linearToDB(peak)
    }
}

func linearToDB(_ value: Double) -> Double {
    guard value > 0 else { return -120 }
    return max(-120, 20 * log10(value))
}

func parseOptions() throws -> Options {
    var options = Options()
    var args = Array(CommandLine.arguments.dropFirst())
    while !args.isEmpty {
        let arg = args.removeFirst()
        switch arg {
        case "--min-duration":
            guard let value = args.first, let seconds = Double(value) else { throw AnalyzeError.usage }
            args.removeFirst()
            options.minDurationSeconds = seconds
        case "--threshold-db":
            guard let value = args.first, let db = Double(value) else { throw AnalyzeError.usage }
            args.removeFirst()
            options.activeThresholdDB = db
        case "--allow-silent-channel":
            options.requireActiveChannels = false
        case "-h", "--help":
            throw AnalyzeError.usage
        default:
            guard options.audioPath == nil else { throw AnalyzeError.usage }
            options.audioPath = arg
        }
    }
    guard options.audioPath != nil else { throw AnalyzeError.usage }
    return options
}

func analyze(options: Options) throws {
    guard let path = options.audioPath else { throw AnalyzeError.usage }
    guard FileManager.default.fileExists(atPath: path) else { throw AnalyzeError.missingFile(path) }

    let url = URL(fileURLWithPath: path)
    guard let file = try? AVAudioFile(forReading: url) else {
        throw AnalyzeError.cannotOpen(path)
    }

    let encodedChannels = Int(file.fileFormat.channelCount)
    let processingChannels = Int(file.processingFormat.channelCount)
    guard encodedChannels == 2 || processingChannels == 2 else {
        throw AnalyzeError.invalidChannelCount(max(encodedChannels, processingChannels))
    }

    let sampleRate = file.processingFormat.sampleRate
    let durationSeconds = Double(file.length) / sampleRate
    guard durationSeconds >= options.minDurationSeconds else {
        throw AnalyzeError.tooShort(actual: durationSeconds, expected: options.minDurationSeconds)
    }

    guard let buffer = AVAudioPCMBuffer(
        pcmFormat: file.processingFormat,
        frameCapacity: 16_384
    ) else {
        throw AnalyzeError.unreadablePCM
    }

    var left = ChannelStats()
    var right = ChannelStats()

    while file.framePosition < file.length {
        try file.read(into: buffer, frameCount: buffer.frameCapacity)
        let frames = Int(buffer.frameLength)
        if frames == 0 { break }

        guard let channels = buffer.floatChannelData else {
            throw AnalyzeError.unreadablePCM
        }

        for i in 0..<frames {
            let leftSample = Double(channels[0][i])
            let rightSample = Double(channels[min(1, processingChannels - 1)][i])
            left.sumSquares += leftSample * leftSample
            right.sumSquares += rightSample * rightSample
            left.peak = max(left.peak, abs(leftSample))
            right.peak = max(right.peak, abs(rightSample))
        }
        left.sampleCount += Int64(frames)
        right.sampleCount += Int64(frames)
    }

    if options.requireActiveChannels {
        if left.rmsDB < options.activeThresholdDB {
            throw AnalyzeError.channelSilent(channel: "left/desktop", db: left.rmsDB, threshold: options.activeThresholdDB)
        }
        if right.rmsDB < options.activeThresholdDB {
            throw AnalyzeError.channelSilent(channel: "right/mic", db: right.rmsDB, threshold: options.activeThresholdDB)
        }
    }

    print("PASS audio file is stereo and measurable")
    print("file: \(path)")
    print(String(format: "duration: %.3fs", durationSeconds))
    print("encoded_channels: \(encodedChannels)")
    print("processing_channels: \(processingChannels)")
    print(String(format: "sample_rate: %.0f Hz", sampleRate))
    print(String(format: "left_desktop_rms_db: %.1f", left.rmsDB))
    print(String(format: "right_mic_rms_db: %.1f", right.rmsDB))
    print(String(format: "left_desktop_peak_db: %.1f", left.peakDB))
    print(String(format: "right_mic_peak_db: %.1f", right.peakDB))
}

do {
    try analyze(options: try parseOptions())
} catch {
    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    fputs("FAIL \(message)\n", stderr)
    exit(1)
}
