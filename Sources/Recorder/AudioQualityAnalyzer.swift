import AVFoundation
import Foundation

struct AudioQualityReport: Codable, Equatable {
    var durationSeconds: Double
    var sampleRate: Double
    var channelCount: Int
    var leftDesktopRMSDB: Double
    var rightMicRMSDB: Double
    var leftDesktopPeakDB: Double
    var rightMicPeakDB: Double
    var warnings: [String]

    enum CodingKeys: String, CodingKey {
        case durationSeconds = "duration_seconds"
        case sampleRate = "sample_rate"
        case channelCount = "channel_count"
        case leftDesktopRMSDB = "left_desktop_rms_db"
        case rightMicRMSDB = "right_mic_rms_db"
        case leftDesktopPeakDB = "left_desktop_peak_db"
        case rightMicPeakDB = "right_mic_peak_db"
        case warnings
    }
}

enum AudioQualityAnalyzer {
    private struct ChannelStats {
        var sumSquares: Double = 0
        var peak: Double = 0
        var sampleCount: Int64 = 0

        var rmsDB: Double { linearToDB(sampleCount > 0 ? sqrt(sumSquares / Double(sampleCount)) : 0) }
        var peakDB: Double { linearToDB(peak) }
    }

    static func analyze(
        audioURL: URL,
        activeThresholdDB: Double = -60
    ) throws -> AudioQualityReport {
        let file = try AVAudioFile(forReading: audioURL)
        let format = file.processingFormat
        let channelCount = Int(format.channelCount)
        let sampleRate = format.sampleRate
        let duration = sampleRate > 0 ? Double(file.length) / sampleRate : 0

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384) else {
            throw CocoaError(.fileReadUnknown)
        }

        var left = ChannelStats()
        var right = ChannelStats()

        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: buffer.frameCapacity)
            let frames = Int(buffer.frameLength)
            if frames == 0 { break }
            guard let channels = buffer.floatChannelData else {
                throw CocoaError(.fileReadUnknown)
            }
            for frame in 0..<frames {
                let leftSample = Double(channels[0][frame])
                let rightSample = Double(channels[min(1, max(channelCount - 1, 0))][frame])
                left.sumSquares += leftSample * leftSample
                right.sumSquares += rightSample * rightSample
                left.peak = max(left.peak, abs(leftSample))
                right.peak = max(right.peak, abs(rightSample))
            }
            left.sampleCount += Int64(frames)
            right.sampleCount += Int64(frames)
        }

        var warnings: [String] = []
        if channelCount != 2 {
            warnings.append("Expected stereo audio, got \(channelCount) channel(s).")
        }
        if left.rmsDB < activeThresholdDB {
            warnings.append(String(format: "Desktop/system channel looks silent: %.1f dB.", left.rmsDB))
        }
        if right.rmsDB < activeThresholdDB {
            warnings.append(String(format: "Microphone channel looks silent: %.1f dB.", right.rmsDB))
        }

        return AudioQualityReport(
            durationSeconds: duration,
            sampleRate: sampleRate,
            channelCount: channelCount,
            leftDesktopRMSDB: left.rmsDB,
            rightMicRMSDB: right.rmsDB,
            leftDesktopPeakDB: left.peakDB,
            rightMicPeakDB: right.peakDB,
            warnings: warnings
        )
    }

    private static func linearToDB(_ value: Double) -> Double {
        guard value > 0 else { return -120 }
        return max(-120, 20 * log10(value))
    }
}
