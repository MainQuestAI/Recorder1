import Foundation
import AVFoundation
import CoreAudio   // AudioConvertHostTimeToNanos (mach_absolute_time -> ns)

/// Produce `audio.m4a` with desktop audio panned hard LEFT (ch0) and mic panned
/// hard RIGHT (ch1).
///
/// Pipeline:
///  1. Read both mono CAFs via `AVAudioFile`.
///  2. Resample each source to a common 48 kHz mono buffer via `AVAudioConverter`.
///  3. Compute the start-time skew from the two `firstHostTime` values
///     (`AudioConvertHostTimeToNanos`) and prepend leading silence to whichever
///     stream started LATER, so both line up at t = 0.
///  4. Interleave into a stereo float buffer (ch0 = desktop, ch1 = mic), padding
///     the shorter side with silence so the file is as long as the longer source.
///  5. Encode to AAC `.m4a` via `AVAudioFile(forWriting:settings:)`.
///
/// Robustness: a missing / empty / unreadable source is treated as pure silence
/// on its channel — the function still produces a valid stereo file. The raw CAFs
/// are never modified or deleted. Throws only on a fatal output-write failure.
enum StereoMixer {

    // MARK: - Tunables

    /// Common output sample rate for the mixed file.
    private static let outputSampleRate: Double = 48_000

    /// AAC bit rate for the encoded `.m4a`.
    private static let outputBitRate: Int = 128_000

    /// Processing block size used while interleaving / writing.
    private static let writeChunkFrames: AVAudioFrameCount = 16_384

    // MARK: - Errors

    enum MixError: LocalizedError {
        case couldNotCreateFormat
        case couldNotCreateConverter
        case couldNotAllocateBuffer
        case bothSourcesEmpty
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .couldNotCreateFormat:    return "Could not create an audio format for mixing."
            case .couldNotCreateConverter: return "Could not create a sample-rate converter."
            case .couldNotAllocateBuffer:  return "Could not allocate an audio buffer for mixing."
            case .bothSourcesEmpty:        return "Both audio sources were empty — nothing to mix."
            case .writeFailed(let why):    return "Failed to write the mixed file: \(why)"
            }
        }
    }

    // MARK: - Public entry point

    static func mix(
        desktopURL: URL,
        micURL: URL,
        desktopResult: CaptureResult,
        micResult: CaptureResult,
        outputURL: URL
    ) throws {
        // 1. Decode + resample each source to 48 kHz mono float samples.
        //    A nil result means "treat as silence" (file missing / empty / unreadable).
        let desktopSamples = loadResampledMono(url: desktopURL)
        let micSamples     = loadResampledMono(url: micURL)

        // Guard: if literally nothing was captured on either side, there is no
        // meaningful file to produce.
        if (desktopSamples?.isEmpty ?? true) && (micSamples?.isEmpty ?? true) {
            throw MixError.bothSourcesEmpty
        }

        // 2. Compute start-skew (in OUTPUT frames) from the two host times.
        //    Whichever stream started later is delayed by `skewFrames` of leading
        //    silence so both align at the earliest shared instant.
        let (desktopLeadFrames, micLeadFrames) = leadingSilenceFrames(
            desktopHostTime: desktopResult.firstHostTime,
            micHostTime: micResult.firstHostTime
        )

        // 3. Materialise each channel as a contiguous 48 kHz float array including
        //    its leading-silence offset.
        let desktopChannel = channel(from: desktopSamples, leadingSilence: desktopLeadFrames)
        let micChannel     = channel(from: micSamples,     leadingSilence: micLeadFrames)

        // 4. Encode the two channels (ch0 = desktop / L, ch1 = mic / R) to AAC m4a.
        try encodeStereoM4A(
            left: desktopChannel,
            right: micChannel,
            to: outputURL
        )
    }

    // MARK: - Decode + resample

    /// Read a mono CAF and resample it to 48 kHz mono `Float`.
    /// Returns `nil` if the file is missing / unreadable / empty, signalling the
    /// caller to treat that channel as silence.
    private static func loadResampledMono(url: URL) -> [Float]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        let inFile: AVAudioFile
        do {
            inFile = try AVAudioFile(forReading: url)
        } catch {
            return nil
        }

        let inFormat = inFile.processingFormat
        let inLength = inFile.length
        guard inLength > 0, inFormat.sampleRate > 0 else { return nil }

        // Target: 48 kHz, mono, non-interleaved float (a single channel array).
        guard let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: outputSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            return nil
        }

        // Fast path: already mono @ 48 kHz float -> just slurp the samples.
        if inFormat.sampleRate == outputSampleRate,
           inFormat.channelCount == 1,
           inFormat.commonFormat == .pcmFormatFloat32 {
            return readAllMono(from: inFile, format: inFormat)
        }

        // Otherwise convert (handles sample-rate change AND any >1ch -> mono
        // downmix, since AVAudioConverter averages channels for a mono target).
        guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            // Conversion unavailable — fall back to a best-effort mono read so we
            // don't silently drop the whole channel.
            return readAllMono(from: inFile, format: inFormat)
        }

        // Read the entire input into one buffer, then convert in one shot.
        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: inFormat,
            frameCapacity: AVAudioFrameCount(inLength)
        ) else {
            return nil
        }
        do {
            try inFile.read(into: inputBuffer)
        } catch {
            return nil
        }
        guard inputBuffer.frameLength > 0 else { return nil }

        // Estimate output capacity from the sample-rate ratio (+ slack for rounding).
        let ratio = outputSampleRate / inFormat.sampleRate
        let estimatedFrames = AVAudioFrameCount((Double(inputBuffer.frameLength) * ratio).rounded(.up)) + 4096
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outFormat,
            frameCapacity: estimatedFrames
        ) else {
            return nil
        }

        // Feed the whole input buffer exactly once, then signal end-of-stream.
        var fed = false
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if fed {
                outStatus.pointee = .endOfStream
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        var convError: NSError?
        let status = converter.convert(to: outputBuffer, error: &convError, withInputFrom: inputBlock)
        if status == .error || convError != nil {
            // Converter failed mid-flight — fall back to a raw mono read.
            return readAllMono(from: inFile, format: inFormat)
        }

        return samples(from: outputBuffer)
    }

    /// Read every frame of a file and return channel-0 samples (downmix by
    /// averaging if the source is multichannel). Used for the fast/fallback paths.
    private static func readAllMono(from file: AVAudioFile, format: AVAudioFormat) -> [Float]? {
        let length = file.length
        guard length > 0 else { return nil }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(length)
        ) else {
            return nil
        }
        // Rewind in case a previous read advanced the cursor.
        file.framePosition = 0
        do {
            try file.read(into: buffer)
        } catch {
            return nil
        }
        return samples(from: buffer)
    }

    /// Extract a mono `[Float]` from a float PCM buffer, averaging channels when
    /// the buffer carries more than one (defensive downmix).
    private static func samples(from buffer: AVAudioPCMBuffer) -> [Float]? {
        let frames = Int(buffer.frameLength)
        guard frames > 0, let channels = buffer.floatChannelData else { return nil }

        let channelCount = Int(buffer.format.channelCount)
        if channelCount <= 1 {
            let ptr = channels[0]
            return Array(UnsafeBufferPointer(start: ptr, count: frames))
        }

        // Downmix: average across all channels.
        var out = [Float](repeating: 0, count: frames)
        let inv = 1.0 / Float(channelCount)
        for ch in 0..<channelCount {
            let ptr = channels[ch]
            for i in 0..<frames {
                out[i] += ptr[i] * inv
            }
        }
        return out
    }

    // MARK: - Alignment

    /// Convert the two first-sample host times into how many 48 kHz frames of
    /// leading silence each stream needs so the EARLIER stream starts at frame 0
    /// and the LATER stream is pushed back by the inter-onset gap.
    ///
    /// Host times are in the `mach_absolute_time` domain; `AudioConvertHostTimeToNanos`
    /// is the canonical converter for that domain.
    private static func leadingSilenceFrames(
        desktopHostTime: UInt64?,
        micHostTime: UInt64?
    ) -> (desktop: Int, mic: Int) {
        guard let d = desktopHostTime, let m = micHostTime else {
            // If either onset is unknown we cannot align — assume coincident starts.
            return (0, 0)
        }

        // Δ nanoseconds between the two onsets (signed via ordering).
        let deltaFrames: Int
        if d == m {
            deltaFrames = 0
        } else if d < m {
            // Desktop started first; mic must be delayed by (m - d).
            let nanos = AudioConvertHostTimeToNanos(m - d)
            deltaFrames = framesForNanos(nanos)
        } else {
            // Mic started first; desktop must be delayed by (d - m).
            let nanos = AudioConvertHostTimeToNanos(d - m)
            deltaFrames = framesForNanos(nanos)
        }

        if d <= m {
            return (0, deltaFrames)   // delay the mic
        } else {
            return (deltaFrames, 0)   // delay the desktop
        }
    }

    /// Nanoseconds -> 48 kHz frame count (rounded to nearest, clamped >= 0).
    private static func framesForNanos(_ nanos: UInt64) -> Int {
        let seconds = Double(nanos) / 1_000_000_000.0
        let frames = (seconds * outputSampleRate).rounded()
        guard frames > 0, frames.isFinite else { return 0 }
        return Int(frames)
    }

    /// Build a single channel array: `leadingSilence` zeros followed by the
    /// resampled samples (or pure silence if the source is nil/empty).
    private static func channel(from samples: [Float]?, leadingSilence: Int) -> [Float] {
        let lead = max(0, leadingSilence)
        guard let samples, !samples.isEmpty else {
            // Source absent -> a run of silence (its leading offset only; the
            // total length is later padded to match the other channel).
            return [Float](repeating: 0, count: lead)
        }
        if lead == 0 { return samples }
        var out = [Float](repeating: 0, count: lead + samples.count)
        // Copy samples in after the leading silence.
        samples.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                (dst.baseAddress! + lead).update(from: src.baseAddress!, count: samples.count)
            }
        }
        return out
    }

    // MARK: - Encode

    /// Interleave two mono channel arrays (left = desktop, right = mic), padding
    /// the shorter to the longer with silence, and encode to AAC `.m4a`.
    private static func encodeStereoM4A(
        left: [Float],
        right: [Float],
        to outputURL: URL
    ) throws {
        let totalFrames = max(left.count, right.count)
        guard totalFrames > 0 else { throw MixError.bothSourcesEmpty }

        // Output PCM format we hand to AVAudioFile (it transcodes to AAC on write).
        // Stereo, 48 kHz, float, non-interleaved (planar channel arrays).
        guard let pcmFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: outputSampleRate,
            channels: 2,
            interleaved: false
        ) else {
            throw MixError.couldNotCreateFormat
        }

        // AAC .m4a settings.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: outputSampleRate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: outputBitRate
        ]

        // Overwrite any stale output from a previous attempt.
        try? FileManager.default.removeItem(at: outputURL)

        let outFile: AVAudioFile
        do {
            outFile = try AVAudioFile(
                forWriting: outputURL,
                settings: settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        } catch {
            throw MixError.writeFailed(error.localizedDescription)
        }

        // Write in fixed-size chunks so we never allocate one giant buffer. Each
        // chunk is copied into a fresh PCM buffer (the `write` can throw, which is
        // awkward to propagate from inside withUnsafeBufferPointer closures).
        var frameOffset = 0
        while frameOffset < totalFrames {
            let chunk = min(Int(writeChunkFrames), totalFrames - frameOffset)

            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: pcmFormat,
                frameCapacity: AVAudioFrameCount(chunk)
            ) else {
                throw MixError.couldNotAllocateBuffer
            }
            buffer.frameLength = AVAudioFrameCount(chunk)

            guard let channelData = buffer.floatChannelData else {
                throw MixError.couldNotAllocateBuffer
            }
            let dstL = channelData[0]
            let dstR = channelData[1]

            for i in 0..<chunk {
                let idx = frameOffset + i
                dstL[i] = idx < left.count  ? left[idx]  : 0
                dstR[i] = idx < right.count ? right[idx] : 0
            }

            do {
                try outFile.write(from: buffer)
            } catch {
                throw MixError.writeFailed(error.localizedDescription)
            }

            frameOffset += chunk
        }

        // `outFile` finalises (closes the AAC stream) when it deinits at scope end.
    }
}
