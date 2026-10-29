import AVFoundation
import CoreAudio
import Foundation

/// Serial-queue writer. Sample timestamps, rather than callback arrival times, keep
/// the microphone on the system tap's host clock even when delivery is delayed.
final class AudioTimelineWriter {
    private var file: AVAudioFile?
    let format: AVAudioFormat
    private var originSeconds: Double?
    private var timelineOffset = 0.0
    private var resumePending = false
    private var converter: AVAudioConverter?
    private var inputRate = 0.0
    private(set) var firstHostTime: UInt64?
    private(set) var frameCount: AVAudioFramePosition = 0
    private(set) var insertedSilenceFrames = 0
    private(set) var failureReason: String?
    var reportGapsAsFailure = true
    var onGap: ((Double) -> Void)?

    init(url: URL, sampleRate: Double) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            throw CocoaError(.fileWriteUnknown)
        }
        self.format = format
        file = try AVAudioFile(forWriting: url, settings: format.settings)
    }

    func resume() { resumePending = true }

    func append(_ input: AVAudioPCMBuffer, hostTime: UInt64, pausedSeconds: Double? = nil) throws {
        guard input.frameLength > 0, let channels = input.floatChannelData, let file else {
            throw CocoaError(.fileWriteUnknown)
        }
        let seconds = Double(AudioConvertHostTimeToNanos(hostTime)) / 1e9
        if originSeconds == nil { originSeconds = seconds; firstHostTime = hostTime }
        if let pausedSeconds { timelineOffset = pausedSeconds }
        if resumePending {
            timelineOffset = seconds - originSeconds! - Double(frameCount) / format.sampleRate
            resumePending = false
        }
        let expected = AVAudioFramePosition(((seconds - originSeconds! - timelineOffset) * format.sampleRate).rounded())
        let missing = expected - frameCount
        // Ignore sub-buffer timestamp jitter, but preserve the WHOLE gap, in bounded chunks.
        if missing > AVAudioFramePosition(format.sampleRate * 0.02) {
            let gap = Double(missing) / format.sampleRate
            var remaining = missing
            let padding = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
            padding.floatChannelData![0].update(repeating: 0, count: 4096)
            while remaining > 0 {
                padding.frameLength = AVAudioFrameCount(min(remaining, 4096))
                try file.write(from: padding)
                frameCount += AVAudioFramePosition(padding.frameLength)
                insertedSilenceFrames += Int(padding.frameLength)
                remaining -= AVAudioFramePosition(padding.frameLength)
            }
            // Preserve honest acceptance: missing samples cannot be recovered by padding.
            if reportGapsAsFailure && gap > 1 { failureReason = String(format: "Microphone capture gap: %.3f seconds; silence inserted to preserve alignment.", gap) }
            onGap?(gap)
        }
        let monoFormat = AVAudioFormat(standardFormatWithSampleRate: input.format.sampleRate, channels: 1)!
        let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: input.frameLength)!
        mono.frameLength = input.frameLength
        let channelCount = Int(input.format.channelCount)
        let interleaved = input.format.isInterleaved
        for frame in 0..<Int(input.frameLength) {
            var sum: Float = 0
            for channel in 0..<channelCount {
                sum += interleaved ? channels[0][frame * channelCount + channel] : channels[channel][frame]
            }
            mono.floatChannelData![0][frame] = sum / Float(channelCount)
        }
        let output: AVAudioPCMBuffer
        if abs(monoFormat.sampleRate - format.sampleRate) > 1 {
            if inputRate != monoFormat.sampleRate {
                converter = AVAudioConverter(from: monoFormat, to: format)
                inputRate = monoFormat.sampleRate
            }
            guard let converter else { throw CocoaError(.fileWriteUnknown) }
            output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(ceil(Double(mono.frameLength) * format.sampleRate / monoFormat.sampleRate) + 128))!
            var supplied = false
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, flag in
                if supplied { flag.pointee = .noDataNow; return nil }
                supplied = true; flag.pointee = .haveData; return mono
            }
            if status == .error { throw error ?? CocoaError(.fileWriteUnknown) as NSError }
        } else { output = mono }
        // Duplicate/overlapping delivery must not shift all later audio to the right.
        let overlap = max(0, frameCount - expected)
        if overlap > AVAudioFramePosition(format.sampleRate * 0.02) {
            let skip = min(Int(overlap), Int(output.frameLength))
            let count = Int(output.frameLength) - skip
            if count == 0 { return }
            memmove(output.floatChannelData![0], output.floatChannelData![0] + skip, count * MemoryLayout<Float>.size)
            output.frameLength = AVAudioFrameCount(count)
        }
        if output.frameLength > 0 {
            try file.write(from: output)
            frameCount += AVAudioFramePosition(output.frameLength)
        }
    }

    /// Include trailing silence when a device stops providing callbacks while idle.
    func finish(at hostTime: UInt64, pausedSeconds: Double) throws {
        guard let originSeconds, let file else { return }
        let end = Double(AudioConvertHostTimeToNanos(hostTime)) / 1e9
        var remaining = AVAudioFramePosition(((end - originSeconds - pausedSeconds) * format.sampleRate).rounded()) - frameCount
        let padding = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
        padding.floatChannelData![0].update(repeating: 0, count: 4096)
        while remaining > 0 {
            padding.frameLength = AVAudioFrameCount(min(remaining, 4096))
            try file.write(from: padding)
            frameCount += AVAudioFramePosition(padding.frameLength)
            insertedSilenceFrames += Int(padding.frameLength)
            remaining -= AVAudioFramePosition(padding.frameLength)
        }
    }

    func close() { file = nil }
}
