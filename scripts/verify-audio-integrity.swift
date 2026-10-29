import AVFoundation
import CoreAudio
import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw NSError(domain: "AudioIntegrity", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

@main
struct AudioIntegrityProbe {
    static func main() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Recorder1Integrity-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        for sparse in [true, false] {
            let path = folder.appendingPathComponent("\(sparse).caf")
            do {
                let file = try AVAudioFile(forWriting: path, settings: format.settings)
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
                for second in 0..<90 {
                    buffer.frameLength = 48_000
                    for frame in 0..<48_000 {
                        let tone = Float(sin(Double(frame) * 2 * .pi * 440 / 48_000) * 0.2)
                        buffer.floatChannelData![0][frame] = !sparse || second == 70 ? tone : 0
                        buffer.floatChannelData![1][frame] = tone
                    }
                    try file.write(from: buffer)
                }
            }
            let report = try AudioQualityAnalyzer.analyze(audioURL: path)
            let integrity = RecordingAcceptance.evaluate(quality: report, capture: .empty)
            try require(integrity.requiresUploadConfirmation == sparse, "sparse audio was incorrectly accepted or healthy audio rejected")
            try require(!sparse || (report.leftLongestSilentSeconds ?? 0) >= 70, "continuous silence was not measured")
            if !sparse {
                let micStart = AudioConvertNanosToHostTime(100_000_000_000)
                let lateDesktop = AudioConvertNanosToHostTime(130_000_000_000)
                let aligned = RecordingAcceptance.evaluate(quality: report, capture: .empty,
                    desktop: CaptureResult(firstHostTime: lateDesktop, sampleRate: 48_000, frameCount: 48_000 * 60),
                    microphone: CaptureResult(firstHostTime: micStart, sampleRate: 48_000, frameCount: 48_000 * 90))
                try require(!aligned.requiresUploadConfirmation, "different onsets with aligned endpoints were incorrectly rejected")
                let missingTail = RecordingAcceptance.evaluate(quality: report, capture: .empty,
                    desktop: CaptureResult(firstHostTime: lateDesktop, sampleRate: 48_000, frameCount: 48_000 * 50),
                    microphone: CaptureResult(firstHostTime: micStart, sampleRate: 48_000, frameCount: 48_000 * 90))
                try require(missingTail.requiresUploadConfirmation, "aligned endpoint check hid an actual missing tail")

                var failed = SystemAudioCaptureMetadata.empty
                failed.systemAudioCaptureFailed = true
                failed.lastFailureReason = "writer failure"
                try require(RecordingAcceptance.evaluate(quality: report, capture: failed).requiresUploadConfirmation,
                            "capture failure was hidden by measurable audio")
                try require(RecordingAcceptance.evaluate(quality: report, capture: .empty,
                    microphone: CaptureResult(failureReason: "microphone write failed")).requiresUploadConfirmation,
                    "microphone failure was hidden by measurable audio")
                try require(RecordingAcceptance.evaluate(quality: report, capture: .empty,
                    desktop: CaptureResult(sampleRate: 48_000, frameCount: 48_000 * 60),
                    microphone: CaptureResult(sampleRate: 48_000, frameCount: 48_000 * 90)).requiresUploadConfirmation,
                    "track duration mismatch was accepted")
            }
        }
        try require(RecordingAcceptance.evaluate(quality: nil, capture: .empty).requiresUploadConfirmation,
                    "failed analysis was accepted")
        if CommandLine.arguments.count > 1 {
            let audio = URL(fileURLWithPath: CommandLine.arguments[1])
            let report = try AudioQualityAnalyzer.analyze(audioURL: audio)
            try require(RecordingAcceptance.evaluate(quality: report, capture: nil).requiresUploadConfirmation,
                        "historical 99% silent recording still accepted")
            print("PASS historical recording is flagged for confirmation; source audio unchanged")
        }
        print("PASS sparse audio, continuous silence, capture failures, missing analysis, duration mismatch, healthy audio")
    }
}
