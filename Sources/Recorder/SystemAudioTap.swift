import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox
import Accelerate
import os

/// Core Audio process tap (global system mix) -> desktop.caf
///
/// Captures the entire system-output mix via a `CATapDescription` process tap wrapped in a
/// private, **tap-only** aggregate device (the canonical AudioCap pattern: default output as the
/// `"master"` sub-device, the tap in the tap-list with drift compensation). The IOProc downmixes
/// each buffer to mono and hands it to a lock-free ring buffer; a dedicated background thread
/// drains that ring to a MONO Float32 `AVAudioFile`. It also records the first sample's mach host
/// time for cross-stream alignment and computes per-buffer RMS for the meter.
///
/// IMPORTANT: the IOProc must NOT call `AVAudioFile.write` or allocate — both block/malloc and
/// overran the ~10 ms realtime deadline, tearing the desktop stream at every IO-buffer boundary
/// (audible as broadband clicks / "distortion"). All disk work lives on the writer thread.
///
/// Silent PCM is legitimate even while an output device is running. Only stalled callbacks and
/// actual route changes rebuild the tap; silence is assessed by recording acceptance afterwards.
final class SystemAudioTap {

    // MARK: - Public callbacks (called on audio / arbitrary threads)

    /// dBFS per buffer (throttled to ~10-20 Hz). Called on the audio thread.
    var onLevelDB: ((Float) -> Void)?
    /// Called on an arbitrary thread on a fatal, unrecoverable error.
    var onFatalError: ((Error) -> Void)?
    /// Called when the default output route changes while recording.
    var onRouteChanged: ((SystemAudioRouteChangeEvent) -> Void)?
    /// Called when callbacks keep firing but the desktop/system channel stays silent.
    var onCaptureFailed: ((String) -> Void)?

    // MARK: - Errors

    enum TapError: LocalizedError {
        case createTapFailed(OSStatus)
        case noDefaultOutputDevice(OSStatus)
        case readDeviceUIDFailed(OSStatus)
        case createAggregateFailed(OSStatus)
        case readTapFormatFailed(OSStatus)
        case invalidTapFormat
        case createIOProcFailed(OSStatus)
        case startDeviceFailed(OSStatus)
        case fileOpenFailed(String)

        var errorDescription: String? {
            switch self {
            case .createTapFailed(let s):
                return "AudioHardwareCreateProcessTap failed (OSStatus \(s)). System Audio Recording permission may be denied."
            case .noDefaultOutputDevice(let s):
                return "Could not read the default system output device (OSStatus \(s))."
            case .readDeviceUIDFailed(let s):
                return "Could not read the output device UID (OSStatus \(s))."
            case .createAggregateFailed(let s):
                return "AudioHardwareCreateAggregateDevice failed (OSStatus \(s))."
            case .readTapFormatFailed(let s):
                return "Could not read kAudioTapPropertyFormat (OSStatus \(s))."
            case .invalidTapFormat:
                return "The tap returned an unusable audio format."
            case .createIOProcFailed(let s):
                return "AudioDeviceCreateIOProcIDWithBlock failed (OSStatus \(s))."
            case .startDeviceFailed(let s):
                return "AudioDeviceStart failed (OSStatus \(s))."
            case .fileOpenFailed(let m):
                return "Could not open the desktop capture file: \(m)"
            }
        }
    }

    // MARK: - State guarded by `lock`

    /// Single lock protecting all the mutable Core Audio handles + flags below. Acquired briefly on
    /// both the control thread and (very briefly) checked against on the audio thread for the
    /// `paused` gate via a dedicated atomic flag, so the realtime path stays lock-light.
    private let lock = OSAllocatedUnfairLock()

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var tapUUID = UUID()
    private var activeConfig = SystemAudioCaptureConfig(
        tapKind: .global,
        deviceRole: .defaultOutput,
        includeSubDevice: true
    )
    private var currentDevice: SystemAudioDeviceSnapshot?
    private var currentTapFormat: SystemAudioTapFormatSummary?
    private var fallbackEvents: [String] = []
    private var captureFailureNotified = false
    private var captureFailureReason: String?
    private var stallRecoveryCount = 0
    private var insertedSilenceFrames = 0
    private var inputSampleRate = 0.0
    private let writerFailure = OSAllocatedUnfairLock<String?>(initialState: nil)

    /// The destination file. Stays open across watchdog rebuilds; finalized only on `stop()`.
    private var timelineWriter: AudioTimelineWriter?
    /// The processing format we write to disk (MONO Float32 at the output device's sample rate).
    private var writeFormat: AVAudioFormat?
    /// The format the tap actually delivers in the IOProc (used to wrap the incoming buffer list).
    private var tapFormat: AVAudioFormat?

    private var destinationURL: URL?
    private var started = false

    // Accumulated capture result.
    private var firstHostTime: UInt64?
    private var capturedSampleRate: Double = 0
    private var capturedSampleRateSource: String?
    /// Frames actually written to disk. Updated ONLY by the writer thread during
    /// a session; read by `stop()` after the writer has been joined.
    private var capturedFrames: AVAudioFramePosition = 0

    // MARK: - Off-realtime disk writer (ring buffer + consumer thread)

    /// Timestamped PCM packets filled by the IOProc and drained by `writerThread`.
    private var ring: TimestampedAudioRingBuffer?
    /// Preallocated mono scratch for multi-channel downmix in the IOProc (no
    /// per-callback allocation). Sized to comfortably exceed any IO buffer.
    private var scratch: UnsafeMutablePointer<Float>?
    private let scratchCapacity = 16_384
    /// Background thread that drains timestamped packets to the timeline writer.
    private var writerThread: Thread?
    /// Set true by `stop()` to tell the writer to drain and exit.
    private let writerShouldStop = OSAllocatedUnfairLock<Bool>(initialState: false)

    private static let log = Logger(subsystem: "com.dingcheng.Recorder1", category: "SystemAudioTap")

    // MARK: - Realtime-path flags (separately lock-protected so the IOProc never blocks on `lock`)

    private let paused = OSAllocatedUnfairLock<Bool>(initialState: false)
    private let pauseTimeline = OSAllocatedUnfairLock<(since: UInt64?, total: Double)>(initialState: (nil, 0))
    private var endHostTime: UInt64 = 0
    private var finalPausedSeconds = 0.0

    /// Host time of the most recent IOProc callback (proves the proc is still firing).
    private let lastCallbackHostTime = OSAllocatedUnfairLock<UInt64>(initialState: 0)

    // MARK: - Watchdog

    private var watchdogTimer: DispatchSourceTimer?
    private let watchdogQueue = DispatchQueue(label: "systemaudiotap.watchdog")
    private let routeListenerQueue = DispatchQueue(label: "systemaudiotap.route-listener")
    private let callbackStallThreshold: TimeInterval = 5
    private var rebuilding = false
    private var defaultOutputListenerBlock: AudioObjectPropertyListenerBlock?
    private var defaultSystemOutputListenerBlock: AudioObjectPropertyListenerBlock?
    private var sampleRateListenerBlock: AudioObjectPropertyListenerBlock?
    private var sampleRateListenerDevice = AudioObjectID(kAudioObjectUnknown)

    // Throttle the meter callback to ~15 Hz.
    private var lastMeterPostHostTime: UInt64 = 0
    private static let meterIntervalNanos: UInt64 = 66_000_000 // ~15 Hz

    // mach timebase, cached.
    private static let timebase: mach_timebase_info_data_t = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return tb
    }()

    private static func hostTimeToNanos(_ hostTime: UInt64) -> UInt64 {
        let tb = timebase
        // Avoid overflow on the multiply for large host times.
        return hostTime / UInt64(tb.denom) * UInt64(tb.numer)
            + (hostTime % UInt64(tb.denom)) * UInt64(tb.numer) / UInt64(tb.denom)
    }

    // MARK: - Public API

    /// Build the tap + aggregate, open the file, install the IOProc and start the device.
    func start(writingTo url: URL) throws {
        lock.lock()
        defer { lock.unlock() }

        guard !started else { return }

        destinationURL = url
        tapUUID = UUID()
        firstHostTime = nil
        capturedFrames = 0
        activeConfig = SystemAudioCaptureConfig(
            tapKind: .global,
            deviceRole: .defaultOutput,
            includeSubDevice: true
        )
        currentDevice = nil
        currentTapFormat = nil
        fallbackEvents = []
        captureFailureNotified = false
        captureFailureReason = nil
        stallRecoveryCount = 0
        insertedSilenceFrames = 0
        writerFailure.withLock { $0 = nil }
        paused.withLock { $0 = false }
        capturedSampleRateSource = nil

        // 1) Build tap + aggregate and read the tap format.
        let built = try buildTapAndAggregateLocked()

        // 2) Open the destination file MONO Float32 at the output device's sample rate.
        // Bluetooth headsets in call mode can report a 48 kHz tap format while the hardware clock
        // is actually 24 kHz. Writing at the tap rate labels the CAF twice as fast.
        guard let writeFmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: built.captureSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            // Clean up the partially-built tap/aggregate before throwing.
            destroyTapAndAggregateLocked()
            throw TapError.invalidTapFormat
        }

        do {
            timelineWriter = try AudioTimelineWriter(url: url, sampleRate: writeFmt.sampleRate)
            timelineWriter?.reportGapsAsFailure = false
        } catch {
            destroyTapAndAggregateLocked()
            throw TapError.fileOpenFailed(error.localizedDescription)
        }

        self.writeFormat = writeFmt
        self.tapFormat = built.tapFormat
        self.capturedSampleRate = built.captureSampleRate
        self.capturedSampleRateSource = built.captureSampleRateSource
        self.inputSampleRate = built.captureSampleRate

        // 3) Spin up the off-realtime writer (ring + drain thread) BEFORE the
        //    IOProc starts producing. preallocated packet headroom; the IOProc
        //    only ever copies into this ring, never touches the disk.
        let newRing = TimestampedAudioRingBuffer()
        pauseTimeline.withLock { $0 = (nil, 0) }
        endHostTime = 0
        finalPausedSeconds = 0
        self.ring = newRing
        self.scratch = UnsafeMutablePointer<Float>.allocate(capacity: scratchCapacity)
        writerShouldStop.withLock { $0 = false }
        startWriterThread(writer: timelineWriter!, ring: newRing)

        // 4) Install IOProc + start the aggregate device.
        do {
            try installIOProcAndStartLocked()
        } catch {
            stopWriterThreadAndDrain()
            self.ring = nil
            self.scratch?.deallocate()
            self.scratch = nil
            timelineWriter = nil
            destroyTapAndAggregateLocked()
            throw error
        }

        started = true

        // Prime watchdog timestamps to "now".
        let now = mach_absolute_time()
        lastCallbackHostTime.withLock { $0 = now }
        installRouteListeners()
        startWatchdog()
    }

    /// Gate writes. Device keeps running, meters keep updating. Thread-safe.
    func setPaused(_ isPaused: Bool) {
        let now = mach_absolute_time()
        pauseTimeline.withLock { value in
            if isPaused, value.since == nil { value.since = now }
            else if !isPaused, let since = value.since {
                value.total += Double(Self.hostTimeToNanos(now - since)) / 1e9
                value.since = nil
            }
        }
        paused.withLock { $0 = isPaused }
    }

    /// Stop the IOProc, destroy the aggregate + tap, finalize the file.
    func stop() -> CaptureResult {
        stopWatchdog()
        let now = mach_absolute_time()
        let pause = pauseTimeline.withLock { $0 }
        endHostTime = pause.since ?? now
        finalPausedSeconds = pause.total

        lock.lock()
        defer { lock.unlock() }
        removeRouteListeners()

        guard started else {
            return CaptureResult(
                firstHostTime: firstHostTime,
                sampleRate: capturedSampleRate,
                frameCount: capturedFrames,
                systemAudio: captureMetadataLocked()
            )
        }
        started = false

        // Tear down Core Audio first: AudioDeviceStop blocks until the last
        // IOProc callback returns, so the producer is fully stopped after this.
        destroyTapAndAggregateLocked()

        // Drain queued packets and trailing silence before finalizing the writer.
        stopWriterThreadAndDrain()

        if let dropped = ring?.totalDropped, dropped > 0 {
            Self.log.error("desktop tap dropped \(dropped) frames (consumer fell behind)")
            captureFailureNotified = true
            captureFailureReason = "System audio writer dropped \(dropped) frames."
        }
        let droppedFrames = ring?.totalDropped ?? 0
        ring = nil
        scratch?.deallocate()
        scratch = nil

        // Release the finalized writer after its thread has joined.
        timelineWriter = nil
        writeFormat = nil
        tapFormat = nil

        var metadata = captureMetadataLocked()
        metadata.firstHostTime = firstHostTime
        metadata.droppedFrames = droppedFrames
        metadata.insertedSilenceFrames = insertedSilenceFrames
        return CaptureResult(
            firstHostTime: firstHostTime,
            sampleRate: capturedSampleRate,
            frameCount: capturedFrames,
            systemAudio: metadata
        )
    }

    // MARK: - Build / teardown (must hold `lock`)

    private struct BuildResult {
        var tapFormat: AVAudioFormat
        var captureSampleRate: Double
        var captureSampleRateSource: String
    }

    /// Create the process tap and the private tap-only aggregate device, and read the tap format.
    /// Caller MUST hold `lock`. On any failure, partially-created objects are destroyed and the
    /// error is thrown.
    @discardableResult
    private func buildTapAndAggregateLocked() throws -> BuildResult {
        // --- 1. Resolve the output device. Prefer Default Output; keep Default System Output as fallback. ---
        var config = activeConfig
        let outputDevice: AudioObjectID
        do {
            outputDevice = try Self.outputDevice(role: config.deviceRole)
        } catch {
            if config.deviceRole == .defaultOutput {
                fallbackEvents.append("default_output_device_unavailable; using default_system_output_device")
                config.deviceRole = .defaultSystemOutput
                activeConfig = config
                outputDevice = try Self.outputDevice(role: config.deviceRole)
            } else {
                throw error
            }
        }

        let outputUID = try Self.deviceUID(outputDevice)
        let outputSnapshot = try Self.deviceSnapshot(deviceID: outputDevice)
        currentDevice = outputSnapshot

        // --- 2. Process tap: global first; watchdog may switch to device-bound if it stays silent. ---
        let desc: CATapDescription
        switch config.tapKind {
        case .global:
            desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        case .deviceBound:
            desc = CATapDescription(__excludingProcesses: [], andDeviceUID: outputUID, withStream: 0)
        case .processMixdown:
            let processes = try Self.audioProcessObjects(
                excludingCurrentProcess: false,
                runningOutputOnly: false
            )
            guard !processes.isEmpty else {
                throw TapError.createTapFailed(kAudioHardwareBadObjectError)
            }
            fallbackEvents.append("process_mixdown_target_count=\(processes.count)")
            desc = CATapDescription(stereoMixdownOfProcesses: processes)
        }
        desc.uuid = tapUUID
        desc.name = "Recorder1 System Audio"
        desc.muteBehavior = .unmuted   // passthrough: the user still hears their audio
        desc.isPrivate = true          // do not advertise this tap system-wide
        if #available(macOS 26.0, *) {
            desc.isProcessRestoreEnabled = true
        }

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(desc, &newTapID)
        guard tapStatus == noErr, newTapID != kAudioObjectUnknown else {
            throw TapError.createTapFailed(tapStatus)
        }
        self.tapID = newTapID

        // --- 3. Private, tap-only aggregate device. Output = master (drift comp off); tap in the
        //        tap-list with drift compensation on. The mic is NOT part of this aggregate. ---
        let aggregateUID = UUID().uuidString
        var aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Recorder System Tap",
            kAudioAggregateDeviceUIDKey: aggregateUID,
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
            aggregateDescription[kAudioAggregateDeviceSubDeviceListKey] = [
                [
                    kAudioSubDeviceUIDKey: outputUID,
                    kAudioSubDeviceDriftCompensationKey: 0
                ]
            ]
        }

        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        let aggStatus = AudioHardwareCreateAggregateDevice(
            aggregateDescription as CFDictionary, &newAggregateID
        )
        guard aggStatus == noErr, newAggregateID != kAudioObjectUnknown else {
            AudioHardwareDestroyProcessTap(newTapID)
            self.tapID = kAudioObjectUnknown
            throw TapError.createAggregateFailed(aggStatus)
        }
        self.aggregateID = newAggregateID

        // --- 4. Read the tap's actual stream format. ---
        let format: AVAudioFormat
        do {
            format = try Self.tapStreamFormat(newTapID)
            currentTapFormat = Self.tapFormatSummary(format)
        } catch {
            AudioHardwareDestroyAggregateDevice(newAggregateID)
            self.aggregateID = kAudioObjectUnknown
            AudioHardwareDestroyProcessTap(newTapID)
            self.tapID = kAudioObjectUnknown
            throw error
        }

        let captureRate = Self.captureSampleRate(tapFormat: format, outputDevice: outputSnapshot)
        if abs(format.sampleRate - captureRate.sampleRate) > 1 {
            fallbackEvents.append(
                "sample_rate_mismatch tap=\(Int(format.sampleRate))Hz output_device=\(Int(outputSnapshot.sampleRate))Hz writing=\(Int(captureRate.sampleRate))Hz"
            )
        }

        return BuildResult(
            tapFormat: format,
            captureSampleRate: captureRate.sampleRate,
            captureSampleRateSource: captureRate.source
        )
    }

    /// Install the IOProc on the aggregate and start it. Caller MUST hold `lock`. Uses the current
    /// `tapFormat` (set by the caller before calling, except during a rebuild where we re-read it).
    private func installIOProcAndStartLocked() throws {
        guard aggregateID != kAudioObjectUnknown else {
            throw TapError.createIOProcFailed(kAudioHardwareBadObjectError)
        }
        guard let tapFmt = tapFormat else {
            throw TapError.invalidTapFormat
        }
        let incomingRate = inputSampleRate

        // The IOProc runs on a Core Audio realtime thread. It captures `self` weakly via an
        // unmanaged-free closure: we keep `self` alive for the recording's duration and only tear
        // the proc down (synchronously) before releasing, so a strong capture is safe and avoids
        // per-callback retain traffic.
        var newProcID: AudioDeviceIOProcID?
        let ioBlock: AudioDeviceIOBlock = { [weak self] _, inInputData, inInputTime, _, _ in
            guard let self else { return }
            self.handleIO(inputData: inInputData, inputTime: inInputTime, tapFormat: tapFmt, sampleRate: incomingRate)
        }

        let createStatus = AudioDeviceCreateIOProcIDWithBlock(
            &newProcID, aggregateID, nil, ioBlock
        )
        guard createStatus == noErr, let procID = newProcID else {
            throw TapError.createIOProcFailed(createStatus)
        }
        self.ioProcID = procID

        let startStatus = AudioDeviceStart(aggregateID, procID)
        guard startStatus == noErr else {
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            self.ioProcID = nil
            throw TapError.startDeviceFailed(startStatus)
        }
    }

    /// Destroy the IOProc, aggregate device, and tap. Caller MUST hold `lock`. Best-effort; safe to
    /// call when partially built. Does NOT touch the file (so a watchdog rebuild keeps appending).
    private func destroyTapAndAggregateLocked() {
        if let procID = ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
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
    }

    // MARK: - IO callback (realtime thread)

    private func handleIO(
        inputData: UnsafePointer<AudioBufferList>,
        inputTime: UnsafePointer<AudioTimeStamp>,
        tapFormat: AVAudioFormat,
        sampleRate: Double
    ) {
        let now = mach_absolute_time()
        lastCallbackHostTime.withLock { $0 = now }

        let channelCount = Int(tapFormat.channelCount)
        guard channelCount > 0, tapFormat.commonFormat == .pcmFormatFloat32 else { return }

        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        guard let firstBuffer = buffers.first,
              let firstData = firstBuffer.mData?.assumingMemoryBound(to: Float.self) else {
            return
        }

        let frameCount: Int
        if tapFormat.isInterleaved {
            frameCount = Int(firstBuffer.mDataByteSize) / (MemoryLayout<Float>.stride * channelCount)
        } else {
            frameCount = Int(firstBuffer.mDataByteSize) / MemoryLayout<Float>.stride
        }
        guard frameCount > 0 else { return }
        let n = vDSP_Length(frameCount)

        // --- Compute RMS for the meter (mix of channel 0, cheap). ---
        var rms: Float = 0
        vDSP_rmsqv(firstData, vDSP_Stride(tapFormat.isInterleaved ? channelCount : 1), &rms, n)
        let db: Float = rms > 0 ? 20 * log10(rms) : -120

        // Throttle meter callbacks to ~15 Hz.
        if Self.hostTimeToNanos(now &- lastMeterPostHostTime) >= Self.meterIntervalNanos {
            lastMeterPostHostTime = now
            onLevelDB?(db)
        }

        // --- Honor pause gate (meters keep updating above; only the write is gated). ---
        if paused.withLock({ $0 }) {
            return
        }

        // --- Downmix to mono and enqueue for the writer thread. ---
        // REALTIME-SAFE ONLY: no allocation, no file I/O, no `self.lock` here. We downmix into a
        // preallocated scratch buffer (vDSP) and hand the samples to a lock-free ring; a background
        // thread drains the ring to disk. The ring/scratch pointers are assigned before the device
        // is started and cleared only after AudioDeviceStop returns (which blocks until this
        // callback finishes), so these reads are safe lock-free with a single producer.
        // Taking `self.lock` here would deadlock against stop()/rebuild, which hold it across
        // AudioDeviceStop.
        guard let ring = self.ring else { return }

        let hostTime = inputTime.pointee.mFlags.contains(.hostTimeValid) ? inputTime.pointee.mHostTime : now
        if firstHostTime == nil { firstHostTime = hostTime }
        let pauseSeconds = pauseTimeline.withLock { $0.total }
        func enqueue(_ data: UnsafePointer<Float>, offset: Int, count: Int) {
            var position = 0
            while position < count {
                let frames = min(count - position, ring.packetFrames)
                let timestamp = hostTime + AudioConvertNanosToHostTime(UInt64(Double(offset + position) / sampleRate * 1e9))
                ring.write(data + position, packet: .init(frames: frames, hostTime: timestamp, sampleRate: sampleRate, pausedSeconds: pauseSeconds))
                position += frames
            }
        }

        if channelCount <= 1 {
            // Already mono: enqueue straight from the input buffer.
            enqueue(firstData, offset: 0, count: frameCount)
        } else if let scratch = self.scratch {
            // Average all channels into mono, in scratch-sized chunks (IO buffers are tiny, so
            // this loop runs once in practice). Taps often report interleaved stereo
            // (L,R,L,R...), so handle both layouts explicitly.
            let total = frameCount
            var offset = 0
            while offset < total {
                let chunk = min(total - offset, scratchCapacity)
                let cn = vDSP_Length(chunk)
                if tapFormat.isInterleaved {
                    for frame in 0..<chunk {
                        var sum: Float = 0
                        let base = (offset + frame) * channelCount
                        for ch in 0..<channelCount {
                            sum += firstData[base + ch]
                        }
                        scratch[frame] = sum / Float(channelCount)
                    }
                } else {
                    memcpy(scratch, firstData + offset, chunk * MemoryLayout<Float>.stride)
                    let availableBuffers = min(channelCount, buffers.count)
                    for ch in 1..<availableBuffers {
                        guard let channel = buffers[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
                        vDSP_vadd(scratch, 1, channel + offset, 1, scratch, 1, cn)
                    }
                    var scale = 1.0 / Float(channelCount)
                    vDSP_vsmul(scratch, 1, &scale, scratch, 1, cn)
                }
                enqueue(scratch, offset: offset, count: chunk)
                offset += chunk
            }
        }
    }

    // MARK: - Writer thread (drains the ring to disk, off the realtime path)

    /// One writer survives route rebuilds. Each packet retains its original source
    /// rate and host clock; quiet intervals and trailing silence retain elapsed time.
    private func startWriterThread(writer: AudioTimelineWriter, ring: TimestampedAudioRingBuffer) {
        let thread = Thread { [weak self] in
            guard let self else { return }
            defer { writer.close() }
            do {
                let scratch = UnsafeMutablePointer<Float>.allocate(capacity: ring.packetFrames)
                defer { scratch.deallocate() }
                while true {
                    let stopRequested = self.writerShouldStop.withLock { $0 }
                    if let packet = ring.read(into: scratch) {
                        let format = AVAudioFormat(standardFormatWithSampleRate: packet.sampleRate, channels: 1)!
                        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(packet.frames))!
                        buffer.frameLength = buffer.frameCapacity
                        buffer.floatChannelData![0].update(from: scratch, count: packet.frames)
                        try writer.append(buffer, hostTime: packet.hostTime, pausedSeconds: packet.pausedSeconds)
                        self.capturedFrames = writer.frameCount
                    } else if stopRequested {
                        try writer.finish(at: self.endHostTime, pausedSeconds: self.finalPausedSeconds)
                        self.capturedFrames = writer.frameCount
                        self.insertedSilenceFrames = writer.insertedSilenceFrames
                        writer.close()
                        break
                    } else { usleep(5_000) }
                }
            } catch {
                self.writerFailure.withLock { $0 = error.localizedDescription }
                self.onFatalError?(error)
            }
        }
        thread.name = "com.dingcheng.Recorder1.desktopWriter"
        thread.qualityOfService = .userInitiated
        writerThread = thread
        thread.start()
    }

    /// Signal the writer to finish draining and block until it exits. Safe to call when no writer
    /// is running. The writer never takes `self.lock`, so calling this under `lock` cannot deadlock.
    private func stopWriterThreadAndDrain() {
        writerShouldStop.withLock { $0 = true }
        if let thread = writerThread {
            while !thread.isFinished { usleep(2_000) }
        }
        writerThread = nil
    }

    // MARK: - Callback-stall recovery

    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: watchdogQueue)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            self?.watchdogTick()
        }
        watchdogTimer = timer
        timer.resume()
    }

    private func stopWatchdog() {
        watchdogTimer?.cancel()
        watchdogTimer = nil
    }

    private func watchdogTick() {
        if paused.withLock({ $0 }) { return }
        lock.lock()
        let isRunning = started && !rebuilding
        let output = lock_currentOutputDeviceLocked()
        lock.unlock()
        guard isRunning else { return }
        guard let output, Self.deviceIsRunningSomewhere(output) else { return }

        // A running output device does not imply audible PCM. Rebuilding on silence destroys
        // healthy taps during meeting pauses and repeatedly removes frames from the timeline.
        let now = mach_absolute_time()
        let lastCallback = lastCallbackHostTime.withLock { $0 }
        let age = Double(Self.hostTimeToNanos(now &- lastCallback)) / 1_000_000_000
        guard age >= callbackStallThreshold else { return }
        lock.lock()
        guard started, !rebuilding else { lock.unlock(); return }
        if stallRecoveryCount >= 2 {
            let notify = !captureFailureNotified
            captureFailureNotified = true
            captureFailureReason = "System audio callbacks stopped after two recovery attempts."
            lock.unlock()
            if notify { onCaptureFailed?("System audio callbacks stopped after two recovery attempts.") }
            return
        }
        stallRecoveryCount += 1
        // Keep dynamic all-process coverage; never pin recording to a process list snapshot.
        activeConfig.tapKind = .global
        activeConfig.includeSubDevice.toggle()
        lock.unlock()
        rebuildTapAndAggregate(reason: "callback_stall_recovery")
    }

    /// Read the current default output device (caller holds `lock`; just a convenience wrapper that
    /// swallows errors so the watchdog stays quiet).
    private func lock_currentOutputDeviceLocked() -> AudioObjectID? {
        return try? Self.outputDevice(role: activeConfig.deviceRole)
    }

    /// Tear down and rebuild BOTH the tap and the aggregate, reinstall the IOProc, and keep writing
    /// to the SAME file. Rebuilding only one is insufficient per the regression report.
    private func rebuildTapAndAggregate(reason: String) {
        lock.lock()

        guard started, !rebuilding else {
            lock.unlock()
            return
        }
        rebuilding = true

        // Destroy existing Core Audio objects (leaves the writer untouched).
        destroyTapAndAggregateLocked()

        // Fresh tap UUID for the rebuild.
        tapUUID = UUID()

        do {
            fallbackEvents.append("rebuild_started: \(reason)")
            let built = try buildTapAndAggregateLocked()
            // The CAF keeps its original rate. Drain the previous rate before starting a new
            // off-thread converter, so queued frames are never relabelled with the new rate.
            self.tapFormat = built.tapFormat
            if writeFormat == nil {
                self.writeFormat = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: built.captureSampleRate,
                    channels: 1,
                    interleaved: false
                )
                self.capturedSampleRate = built.captureSampleRate
                self.capturedSampleRateSource = built.captureSampleRateSource
            }
            // Each queued packet carries its own source rate and host time. A route
            // rebuild never restarts the disk writer or reinterprets queued samples.
            inputSampleRate = built.captureSampleRate
            try installIOProcAndStartLocked()
            installOutputRateListenerLocked()
        } catch {
            captureFailureNotified = true
            captureFailureReason = error.localizedDescription
            rebuilding = false
            lock.unlock()
            // Rebuild failed: this is fatal for the desktop stream. Surface it; the mic recording
            // and raw desktop-so-far file remain intact.
            onFatalError?(error)
            return
        }

        // Reset watchdog clocks so we give the fresh tap a fair window before judging it again.
        let now = mach_absolute_time()
        lastCallbackHostTime.withLock { $0 = now }

        rebuilding = false
        lock.unlock()
    }

    private func installRouteListeners() {
        removeRouteListeners()
        installOutputRateListenerLocked()

        var defaultOutputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let defaultOutputBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleRouteChanged(reason: "default_output_device_changed")
        }
        if AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultOutputAddress,
            routeListenerQueue,
            defaultOutputBlock
        ) == noErr {
            defaultOutputListenerBlock = defaultOutputBlock
        }

        var defaultSystemAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let defaultSystemBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleRouteChanged(reason: "default_system_output_device_changed")
        }
        if AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultSystemAddress,
            routeListenerQueue,
            defaultSystemBlock
        ) == noErr {
            defaultSystemOutputListenerBlock = defaultSystemBlock
        }
    }

    private func removeRouteListeners() {
        removeOutputRateListener()
        if let defaultOutputListenerBlock {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                routeListenerQueue,
                defaultOutputListenerBlock
            )
        }
        defaultOutputListenerBlock = nil

        if let defaultSystemOutputListenerBlock {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                routeListenerQueue,
                defaultSystemOutputListenerBlock
            )
        }
        defaultSystemOutputListenerBlock = nil
    }

    private func removeOutputRateListener() {
        if let sampleRateListenerBlock {
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(sampleRateListenerDevice, &address, routeListenerQueue, sampleRateListenerBlock)
        }
        sampleRateListenerBlock = nil
        sampleRateListenerDevice = kAudioObjectUnknown
    }

    private func installOutputRateListenerLocked() {
        guard let device = currentDevice?.id else { return }
        if sampleRateListenerDevice == device { return }
        removeOutputRateListener()
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleRouteChanged(reason: "output_sample_rate_changed")
        }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        if AudioObjectAddPropertyListenerBlock(device, &address, routeListenerQueue, block) == noErr {
            sampleRateListenerDevice = device
            sampleRateListenerBlock = block
        }
    }

    private func handleRouteChanged(reason: String) {
        lock.lock()
        let shouldRebuild = started && !rebuilding
        let before = currentDevice
        let after = try? Self.deviceSnapshot(deviceID: Self.outputDevice(role: activeConfig.deviceRole))
        if before?.uid == after?.uid, before?.sampleRate == after?.sampleRate {
            lock.unlock()
            return
        }
        stallRecoveryCount = 0
        lock.unlock()

        let event = SystemAudioRouteChangeEvent(
            at: Date(),
            reason: reason,
            before: before,
            after: after
        )
        onRouteChanged?(event)

        if shouldRebuild {
            rebuildTapAndAggregate(reason: reason)
        }
    }

    private func captureMetadataLocked() -> SystemAudioCaptureMetadata {
        SystemAudioCaptureMetadata(
            config: activeConfig,
            device: currentDevice,
            tapFormat: currentTapFormat,
            captureSampleRate: capturedSampleRate > 0 ? capturedSampleRate : nil,
            captureSampleRateSource: capturedSampleRateSource,
            fallbackEvents: fallbackEvents,
            routeChanges: [],
            systemAudioCaptureFailed: captureFailureNotified || writerFailure.withLock { $0 != nil },
            lastFailureReason: captureFailureReason ?? writerFailure.withLock { $0 }
        )
    }

    // MARK: - Core Audio property helpers

    /// Read the requested output device ID.
    static func outputDevice(role: SystemAudioDeviceRole) throws -> AudioObjectID {
        let selector: AudioObjectPropertySelector = role == .defaultOutput
            ? kAudioHardwarePropertyDefaultOutputDevice
            : kAudioHardwarePropertyDefaultSystemOutputDevice
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else {
            throw TapError.noDefaultOutputDevice(status)
        }
        return deviceID
    }

    /// Read a device's UID string.
    static func deviceUID(_ deviceID: AudioObjectID) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        // CoreAudio writes a retained CFString into the pointer; bridge it to Swift afterward.
        var cfUID: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &cfUID)
        guard status == noErr, let uid = cfUID?.takeRetainedValue() else {
            throw TapError.readDeviceUIDFailed(status)
        }
        return uid as String
    }

    static func deviceName(_ deviceID: AudioObjectID) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfName: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &cfName)
        guard status == noErr, let name = cfName?.takeRetainedValue() else {
            return "Unknown Audio Device"
        }
        return name as String
    }

    static func nominalSampleRate(_ deviceID: AudioObjectID) -> Double {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var sampleRate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &sampleRate)
        return status == noErr ? sampleRate : 0
    }

    static func deviceSnapshot(deviceID: AudioObjectID) throws -> SystemAudioDeviceSnapshot {
        SystemAudioDeviceSnapshot(
            id: UInt32(deviceID),
            uid: try deviceUID(deviceID),
            name: try deviceName(deviceID),
            sampleRate: nominalSampleRate(deviceID),
            isRunningSomewhere: deviceIsRunningSomewhere(deviceID)
        )
    }

    static func captureSampleRate(
        tapFormat: AVAudioFormat,
        outputDevice: SystemAudioDeviceSnapshot
    ) -> (sampleRate: Double, source: String) {
        let deviceRate = outputDevice.sampleRate
        if deviceRate >= 8_000, deviceRate <= 384_000 {
            return (deviceRate, "output_device_nominal")
        }
        return (tapFormat.sampleRate, "tap_format")
    }

    /// Read `kAudioTapPropertyFormat` ('tfmt') and build an `AVAudioFormat`.
    static func tapStreamFormat(_ tapID: AudioObjectID) throws -> AVAudioFormat {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        guard status == noErr else {
            throw TapError.readTapFormatFailed(status)
        }
        guard asbd.mSampleRate > 0, asbd.mChannelsPerFrame > 0,
              let format = AVAudioFormat(streamDescription: &asbd) else {
            throw TapError.invalidTapFormat
        }
        return format
    }

    static func tapFormatSummary(_ format: AVAudioFormat) -> SystemAudioTapFormatSummary {
        SystemAudioTapFormatSummary(
            sampleRate: format.sampleRate,
            channelCount: Int(format.channelCount),
            isInterleaved: format.isInterleaved,
            commonFormat: String(describing: format.commonFormat)
        )
    }

    /// Is the device currently running an IO stream somewhere on the system?
    static func deviceIsRunningSomewhere(_ deviceID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &running)
        guard status == noErr else { return false }
        return running != 0
    }

    static func audioProcessObjects(excludingCurrentProcess: Bool, runningOutputOnly: Bool) throws -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        )
        guard status == noErr, dataSize >= UInt32(MemoryLayout<AudioObjectID>.size) else {
            return []
        }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var processObjects = [AudioObjectID](repeating: kAudioObjectUnknown, count: count)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &processObjects
        )
        guard status == noErr else { return [] }

        let currentPID = pid_t(ProcessInfo.processInfo.processIdentifier)
        return processObjects.filter { processObject in
            processObject != kAudioObjectUnknown
                && (!excludingCurrentProcess || Self.processPID(processObject) != currentPID)
                && (!runningOutputOnly || Self.processIsRunningOutput(processObject))
        }
    }

    private static func processIsRunningOutput(_ processObject: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(processObject, &address, 0, nil, &size, &running)
        return status == noErr && running != 0
    }

    private static func processPID(_ processObject: AudioObjectID) -> pid_t? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid = pid_t(0)
        var size = UInt32(MemoryLayout<pid_t>.size)
        let status = AudioObjectGetPropertyData(processObject, &address, 0, nil, &size, &pid)
        return status == noErr ? pid : nil
    }
}
