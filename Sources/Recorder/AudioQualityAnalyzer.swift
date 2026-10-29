import AVFoundation
import CoreAudio
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
    var leftActiveFraction: Double? = nil
    var leftLongestSilentSeconds: Double? = nil

    enum CodingKeys: String, CodingKey {
        case durationSeconds = "duration_seconds"
        case sampleRate = "sample_rate"
        case channelCount = "channel_count"
        case leftDesktopRMSDB = "left_desktop_rms_db"
        case rightMicRMSDB = "right_mic_rms_db"
        case leftDesktopPeakDB = "left_desktop_peak_db"
        case rightMicPeakDB = "right_mic_peak_db"
        case warnings
        case leftActiveFraction = "left_active_fraction"
        case leftLongestSilentSeconds = "left_longest_silent_seconds"
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
        guard channelCount > 0, sampleRate > 0, file.length > 0 else { throw CocoaError(.fileReadCorruptFile) }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384) else {
            throw CocoaError(.fileReadUnknown)
        }

        var left = ChannelStats()
        var right = ChannelStats()
        var windowSquares = 0.0
        var windowFrames = 0
        var activeSeconds = 0.0
        var silentSeconds = 0.0
        var longestSilence = 0.0
        func finishWindow() {
            guard windowFrames > 0 else { return }
            let seconds = Double(windowFrames) / sampleRate
            if linearToDB(sqrt(windowSquares / Double(windowFrames))) > activeThresholdDB {
                activeSeconds += seconds
                silentSeconds = 0
            } else {
                silentSeconds += seconds
                longestSilence = max(longestSilence, silentSeconds)
            }
            windowSquares = 0
            windowFrames = 0
        }

        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: buffer.frameCapacity)
            let frames = Int(buffer.frameLength)
            if frames == 0 { throw CocoaError(.fileReadCorruptFile) }
            guard let channels = buffer.floatChannelData else {
                throw CocoaError(.fileReadUnknown)
            }
            for frame in 0..<frames {
                let leftSample = Double(channels[0][frame])
                let rightSample = Double(channels[min(1, max(channelCount - 1, 0))][frame])
                guard leftSample.isFinite, rightSample.isFinite else { throw CocoaError(.fileReadCorruptFile) }
                left.sumSquares += leftSample * leftSample
                right.sumSquares += rightSample * rightSample
                left.peak = max(left.peak, abs(leftSample))
                right.peak = max(right.peak, abs(rightSample))
                windowSquares += leftSample * leftSample
                windowFrames += 1
                if windowFrames >= Int(sampleRate) { finishWindow() }
            }
            left.sampleCount += Int64(frames)
            right.sampleCount += Int64(frames)
        }
        finishWindow()

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
            warnings: warnings,
            leftActiveFraction: duration > 0 ? activeSeconds / duration : 0,
            leftLongestSilentSeconds: longestSilence
        )
    }

    private static func linearToDB(_ value: Double) -> Double {
        guard value > 0 else { return -120 }
        return max(-120, 20 * log10(value))
    }
}

enum RecordingAcceptance {
    static func rawCapture(at url: URL, failureReason: String? = nil, firstHostTime: UInt64? = nil) -> CaptureResult? {
        guard let file = try? AVAudioFile(forReading: url) else {
            return failureReason.map { CaptureResult(failureReason: $0) }
        }
        return CaptureResult(firstHostTime: firstHostTime, sampleRate: file.processingFormat.sampleRate, frameCount: file.length, failureReason: failureReason)
    }

    static func evaluate(
        quality: AudioQualityReport?,
        capture: SystemAudioCaptureMetadata?,
        desktop: CaptureResult? = nil,
        microphone: CaptureResult? = nil
    ) -> CaptureIntegrity {
        guard let quality else {
            return .degraded(issues: ["Audio quality analysis did not complete; recording is unverified."])
        }
        var issues: [String] = []
        if let reason = microphone?.failureReason { issues.append("Microphone capture failed: \(reason)") }
        if capture?.systemAudioCaptureFailed == true {
            issues.append(capture?.lastFailureReason ?? "System audio capture reported a failure.")
        }
        if quality.channelCount != 2 || quality.durationSeconds <= 0 {
            issues.append("Expected a non-empty stereo recording.")
        }
        let micActive = quality.rightMicRMSDB > -80 || quality.rightMicPeakDB > -60
        if quality.leftDesktopRMSDB < -80 && quality.leftDesktopPeakDB < -60 {
            issues.append("Desktop/system channel is silent.")
        } else if micActive, quality.durationSeconds >= 30,
                  let fraction = quality.leftActiveFraction, fraction < 0.05,
                  (quality.leftLongestSilentSeconds ?? 0) >= 30 {
            issues.append("System audio is active for less than 5% of the recording; confirm that remote voices are present.")
        }
        if let desktop, let microphone, desktop.sampleRate > 0, microphone.sampleRate > 0 {
            let desktopDuration = Double(desktop.frameCount) / desktop.sampleRate
            let micDuration = Double(microphone.frameCount) / microphone.sampleRate
            var endDifference = desktopDuration - micDuration
            // StereoMixer aligns first-sample onsets. Compare the aligned endpoints,
            // not raw lengths: an idle desktop tap can legitimately start much later.
            if let d = desktop.firstHostTime, let m = microphone.firstHostTime {
                let delta = Double(AudioConvertHostTimeToNanos(d >= m ? d - m : m - d)) / 1e9
                endDifference += d >= m ? delta : -delta
            }
            if abs(endDifference) > max(1, quality.durationSeconds * 0.01) {
                issues.append("System and microphone track durations differ; audio may be incomplete or misaligned.")
            }
        }
        return issues.isEmpty ? .passed() : .degraded(issues: issues)
    }
}
