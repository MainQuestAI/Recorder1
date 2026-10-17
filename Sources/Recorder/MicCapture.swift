import Foundation
@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import os

/// Microphone capture via `AVAudioEngine`'s input node, written MONO to `mic.caf`.
///
/// Design notes (see research-notes "mic-capture-and-sync"):
/// - We deliberately run this as an *independent* engine from the system-audio tap.
///   The model records both sources to separate CAFs and `StereoMixer` aligns them
///   afterward using each stream's first-sample host time (the "merge-on-stop"
///   fallback path). That is why `start()` records `firstHostTime` from the very
///   first delivered buffer's `AVAudioTime`.
/// - The input format is taken LIVE from the hardware (`inputFormat(forBus:)`) — we
///   never hardcode 44.1/48 kHz, or AVAudioEngine asserts on a sample-rate mismatch
///   (Bluetooth mics / AirPods commonly run 16 kHz mono input).
/// - The tap block fires on a real-time audio thread. This class only *invokes* its
///   `onLevelDB` / `onFatalError` callbacks from that thread; the model is responsible
///   for hopping to main before touching UI/model state.
///
/// Concurrency: written for Swift 5 language mode. Mutable state touched from both the
/// audio thread (tap block) and the main thread (`start`/`stop`/`setPaused`) is guarded
/// by `OSAllocatedUnfairLock`.
final class MicCapture {

    /// dBFS per buffer (computed via `RMSMeter`). Called on the audio thread.
    var onLevelDB: ((Float) -> Void)?
    /// Called on an arbitrary thread when the engine fails fatally.
    var onFatalError: ((Error) -> Void)?

    // MARK: - Errors

    enum MicError: LocalizedError {
        case couldNotCreateFile(URL, underlying: Error)
        case invalidInputFormat
        case inputDeviceUnavailable(String)
        case setInputDeviceFailed(String, OSStatus)

        var errorDescription: String? {
            switch self {
            case .couldNotCreateFile(let url, let underlying):
                return "Could not open mic file at \(url.lastPathComponent): \(underlying.localizedDescription)"
            case .invalidInputFormat:
                return "Microphone reported an unusable input format (0 channels or 0 Hz)."
            case .inputDeviceUnavailable(let uid):
                return "Selected microphone is no longer available: \(uid)"
            case .setInputDeviceFailed(let uid, let status):
                return "Could not use selected microphone \(uid) (OSStatus \(status))."
            }
        }
    }

    // MARK: - Audio objects

    /// The engine is created lazily per `start()` so a stop/start cycle gets a fresh
    /// graph (and re-reads the current input device format).
    private var engine = AVAudioEngine()
    private let controlQueue = DispatchQueue(label: "com.dingcheng.Recorder1.mic-control")
    private var configurationObserver: NSObjectProtocol?
    private var preferredUID: String?
    private var monoWriteFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var failureReason: String?
    private var lastBufferHostTime: UInt64?
    private var previousBufferDuration = 0.0

    // MARK: - Shared, lock-protected state

    /// Guards everything below; locked briefly inside the real-time tap block.
    private let lock = OSAllocatedUnfairLock()

    /// Destination file. Created on `start`, finalized (set nil) on `stop`.
    private var file: AVAudioFile?

    /// When true, the tap block computes meters but does NOT write to disk.
    private var paused = false

    /// Host time (mach_absolute_time domain) of the first buffer we wrote. `nil` until
    /// the first non-paused buffer arrives.
    private var firstHostTime: UInt64?

    /// Sample rate actually used by the input hardware (and thus the file).
    private var sampleRate: Double = 0

    /// Total frames written to disk.
    private var frameCount: AVAudioFramePosition = 0

    /// Whether a tap is currently installed / engine running.
    private var running = false
    private var currentDevice: AudioInputDeviceInfo?

    var activeInputDevice: AudioInputDeviceInfo? {
        lock.withLock { currentDevice }
    }

    // MARK: - Authorization

    /// Checks / requests microphone (audio) capture permission.
    /// On macOS the capture-permission path is `AVCaptureDevice` (the
    /// `AVAudioSession.requestRecordPermission` API is iOS-only).
    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    // MARK: - Start

    /// Begin capturing the microphone, writing MONO Float32 to `url` (CAF).
    func start(writingTo url: URL, preferredInputDeviceUID: String? = nil) throws {
        try controlQueue.sync { try startOnControlQueue(writingTo: url, preferredInputDeviceUID: preferredInputDeviceUID) }
    }

    private func startOnControlQueue(writingTo url: URL, preferredInputDeviceUID: String?) throws {
        guard !lock.withLock({ running }) else { return }
        engine = AVAudioEngine()
        preferredUID = preferredInputDeviceUID
        if let preferredInputDeviceUID,
           !preferredInputDeviceUID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try applyPreferredInputDevice(uid: preferredInputDeviceUID)
        }

        // Pull the LIVE hardware input format — never hardcode the sample rate.
        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)

        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            throw MicError.invalidInputFormat
        }

        // We always write a single (mono) channel; downmix happens in the tap block
        // when the input has more than one channel.
        guard let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: inputFormat.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw MicError.invalidInputFormat
        }

        // Open the destination file. Float32 mono PCM in a CAF container is cheap and
        // append-friendly; writing the file's processing format == monoFormat avoids
        // any implicit conversion on write.
        let outFile: AVAudioFile
        do {
            outFile = try AVAudioFile(
                forWriting: url,
                settings: monoFormat.settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        } catch {
            throw MicError.couldNotCreateFile(url, underlying: error)
        }

        // Reset shared state under the lock before the tap can fire.
        lock.withLock {
            self.file = outFile
            self.paused = false
            self.firstHostTime = nil
            self.sampleRate = inputFormat.sampleRate
            self.frameCount = 0
            self.running = true
            self.currentDevice = resolvedCurrentInputDevice(preferredInputDeviceUID: preferredInputDeviceUID)
            self.monoWriteFormat = monoFormat
            self.converter = nil
            self.failureReason = nil
            self.lastBufferHostTime = nil
        }

        do { try installTapAndStart() }
        catch {
            inputNode.removeTap(onBus: 0)
            lock.withLock { self.file = nil; self.running = false }
            throw error
        }
    }

    private func installTapAndStart() throws {
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 1, interleaved: false),
              let output = monoWriteFormat else { throw MicError.invalidInputFormat }
        let conversion = abs(mono.sampleRate - output.sampleRate) > 1 ? AVAudioConverter(from: mono, to: output) : nil
        if abs(mono.sampleRate - output.sampleRate) > 1 && conversion == nil { throw MicError.invalidInputFormat }
        lock.withLock { converter = conversion }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, when in
            self?.handleBuffer(buffer, when: when, monoFormat: mono)
        }
        engine.prepare()
        try engine.start()
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] notification in
            guard let source = notification.object as? AVAudioEngine else { return }
            self?.controlQueue.async { [weak self] in self?.recoverConfiguration(source: source) }
        }
    }

    private func recoverConfiguration(source: AVAudioEngine) {
        guard source === engine, lock.withLock({ running }) else { return }
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine = AVAudioEngine()
        do {
            if let preferredUID, !preferredUID.isEmpty { try applyPreferredInputDevice(uid: preferredUID) }
            try installTapAndStart()
            lock.withLock { currentDevice = resolvedCurrentInputDevice(preferredInputDeviceUID: preferredUID) }
        } catch {
            lock.withLock { failureReason = error.localizedDescription }
            onFatalError?(error)
        }
    }

    // MARK: - Real-time tap block

    /// Called on a real-time audio thread for every captured buffer.
    private func handleBuffer(_ buffer: AVAudioPCMBuffer, when: AVAudioTime, monoFormat: AVAudioFormat) {
        // Always compute a meter level, even while paused, so the UI keeps moving.
        let db = RMSMeter.dBFS(buffer)
        onLevelDB?(db)

        // Determine the host time of this buffer (mach_absolute_time domain).
        let hostTime = when.isHostTimeValid ? when.hostTime : mach_absolute_time()

        // Build (or reuse) a mono buffer to write. If the input is already mono we can
        // write the incoming buffer directly; otherwise we downmix by averaging.
        let frames = buffer.frameLength
        guard frames > 0 else { return }

        let writeBuffer: AVAudioPCMBuffer
        if buffer.format.channelCount == 1 && buffer.format.commonFormat == .pcmFormatFloat32 {
            writeBuffer = buffer
        } else if let mono = MicCapture.downmixToMono(buffer, monoFormat: monoFormat) {
            writeBuffer = mono
        } else {
            // Format we can't handle (e.g. non-Float32 and downmix failed); skip safely.
            return
        }

        // Append to disk under the lock (respecting pause + post-stop guards).
        lock.withLock {
            guard self.running, !self.paused, let file = self.file else { return }
            do {
                // Use callback arrival time for continuity across rebuilt hardware clocks.
                let now = mach_absolute_time()
                if let last = lastBufferHostTime, now > last {
                    let gap = Double(AudioConvertHostTimeToNanos(now - last)) / 1_000_000_000 - previousBufferDuration
                    if gap > 0.02, let outputFormat = monoWriteFormat {
                        let padFrames = AVAudioFrameCount(min(gap, 3) * sampleRate)
                        if let padding = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: max(1, padFrames)) {
                            padding.frameLength = padFrames
                            padding.floatChannelData?[0].update(repeating: 0, count: Int(padFrames))
                            try file.write(from: padding)
                            self.frameCount += AVAudioFramePosition(padFrames)
                        }
                        if gap > 3 { failureReason = "Microphone callback gap exceeded three seconds." }
                    }
                }
                lastBufferHostTime = now
                previousBufferDuration = Double(buffer.frameLength) / buffer.format.sampleRate
                if let converter, let outputFormat = monoWriteFormat {
                    let capacity = AVAudioFrameCount(ceil(Double(writeBuffer.frameLength) * sampleRate / writeBuffer.format.sampleRate) + 128)
                    guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { throw MicError.invalidInputFormat }
                    var supplied = false
                    var conversionError: NSError?
                    let status = converter.convert(to: output, error: &conversionError) { _, flag in
                        if supplied { flag.pointee = .noDataNow; return nil }
                        supplied = true; flag.pointee = .haveData; return writeBuffer
                    }
                    if status == .error { throw conversionError ?? CocoaError(.fileWriteUnknown) as NSError }
                    if output.frameLength > 0 { try file.write(from: output); self.frameCount += AVAudioFramePosition(output.frameLength) }
                } else {
                    try file.write(from: writeBuffer)
                    self.frameCount += AVAudioFramePosition(writeBuffer.frameLength)
                }
                if self.firstHostTime == nil {
                    self.firstHostTime = hostTime
                }
            } catch {
                // A write failure is fatal for this capture; report once and stop writing.
                self.failureReason = error.localizedDescription
                self.running = false
                self.file = nil
                self.onFatalError?(error)
            }
        }
    }

    /// Average all channels of `buffer` into a single mono Float32 buffer with `monoFormat`.
    /// Returns nil if the source isn't Float32-accessible.
    private static func downmixToMono(_ buffer: AVAudioPCMBuffer, monoFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = buffer.frameLength
        guard frames > 0 else {
            return AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: 1)
        }
        guard let channels = buffer.floatChannelData else { return nil }
        let channelCount = Int(buffer.format.channelCount)

        guard let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: frames) else {
            return nil
        }
        mono.frameLength = frames
        guard let dst = mono.floatChannelData?[0] else { return nil }

        let n = Int(frames)
        if channelCount == 1 {
            // Straight copy (covers the rare case the caller passed a 1-ch non-shortcut buffer).
            dst.update(from: channels[0], count: n)
        } else {
            let inv = 1.0 / Float(channelCount)
            for i in 0..<n {
                var sum: Float = 0
                for ch in 0..<channelCount {
                    sum += channels[ch][i]
                }
                dst[i] = sum * inv
            }
        }
        return mono
    }

    // MARK: - Pause

    /// Gate writes without tearing down the engine; meters keep updating while paused.
    func setPaused(_ paused: Bool) {
        lock.withLock {
            self.paused = paused
            self.lastBufferHostTime = nil
        }
    }

    // MARK: - Stop

    /// Stop the engine, finalize the file, and return what was captured.
    func stop() -> CaptureResult {
        controlQueue.sync { stopOnControlQueue() }
    }

    private func stopOnControlQueue() -> CaptureResult {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        // Stop the running graph first so no more buffers arrive after we drop the file.
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        } else {
            // Defensive: remove the tap even if the engine never fully started.
            engine.inputNode.removeTap(onBus: 0)
        }

        // Snapshot + finalize state. Setting `file = nil` flushes/closes the AVAudioFile.
        return lock.withLock {
            let result = CaptureResult(
                firstHostTime: self.firstHostTime,
                sampleRate: self.sampleRate,
                frameCount: self.frameCount,
                failureReason: self.failureReason
            )
            self.running = false
            self.file = nil   // releasing the AVAudioFile finalizes the CAF on disk
            self.currentDevice = nil
            return result
        }
    }

    private func applyPreferredInputDevice(uid: String) throws {
        let deviceID: AudioDeviceID
        do {
            deviceID = try AudioDeviceCatalog.inputDeviceID(uid: uid)
        } catch {
            throw MicError.inputDeviceUnavailable(uid)
        }

        guard let audioUnit = engine.inputNode.audioUnit else {
            throw MicError.setInputDeviceFailed(uid, kAudioHardwareBadObjectError)
        }

        var mutableDeviceID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw MicError.setInputDeviceFailed(uid, status)
        }
    }

    private func resolvedCurrentInputDevice(preferredInputDeviceUID: String?) -> AudioInputDeviceInfo? {
        if let preferredInputDeviceUID,
           !preferredInputDeviceUID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return AudioDeviceCatalog.inputDevices().first { $0.uid == preferredInputDeviceUID }
        }
        return AudioDeviceCatalog.defaultInputDevice()
    }
}
