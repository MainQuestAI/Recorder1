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
/// macOS 26 has a confirmed regression where `AudioHardwareCreateProcessTap` + aggregate silently
/// delivers all-zero PCM after extended uptime / sample-rate / Bluetooth changes while the IOProc
/// keeps firing. We run a WATCHDOG: if RMS ≈ 0 for ~3s while the default output device is active,
/// we tear down BOTH the tap and the aggregate and rebuild them, continuing to append to the SAME
/// `AVAudioFile`.
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

    /// The destination file. Stays open across watchdog rebuilds; finalized only on `stop()`.
    private var file: AVAudioFile?
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

    /// Filled by the IOProc (producer), drained by `writerThread` (consumer).
    private var ring: FloatRingBuffer?
    /// Preallocated mono scratch for multi-channel downmix in the IOProc (no
    /// per-callback allocation). Sized to comfortably exceed any IO buffer.
    private var scratch: UnsafeMutablePointer<Float>?
    private let scratchCapacity = 16_384
    /// Background thread that drains `ring` to `file`.
    private var writerThread: Thread?
    /// Set true by `stop()` to tell the writer to drain and exit.
    private let writerShouldStop = OSAllocatedUnfairLock<Bool>(initialState: false)

    private static let log = Logger(subsystem: "com.dingcheng.Recorder1", category: "SystemAudioTap")

    // MARK: - Realtime-path flags (separately lock-protected so the IOProc never blocks on `lock`)

    private let paused = OSAllocatedUnfairLock<Bool>(initialState: false)

    /// Host time (mach) of the last buffer the IOProc observed with non-trivial RMS. Used by the
    /// watchdog to detect the zero-buffer regression. Initialized at start.
    private let lastLoudHostTime = OSAllocatedUnfairLock<UInt64>(initialState: 0)
    /// Host time of the most recent IOProc callback (proves the proc is still firing).
    private let lastCallbackHostTime = OSAllocatedUnfairLock<UInt64>(initialState: 0)

    // MARK: - Watchdog

    private var watchdogTimer: DispatchSourceTimer?
    private let watchdogQueue = DispatchQueue(label: "systemaudiotap.watchdog")
    private let routeListenerQueue = DispatchQueue(label: "systemaudiotap.route-listener")
    /// If output is audibly running but the tap delivers ~silence for this long, rebuild.
    private let watchdogSilenceThreshold: TimeInterval = 3.0
    private let fallbackSilenceThreshold: TimeInterval = 1.5
    private var rebuilding = false
    private var defaultOutputListenerBlock: AudioObjectPropertyListenerBlock?
    private var defaultSystemOutputListenerBlock: AudioObjectPropertyListenerBlock?

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
            // AVAudioFile flushes per write -> at most one buffer lost on crash.
            let f = try AVAudioFile(
                forWriting: url,
                settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: writeFmt.sampleRate,
                    AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true,
                    AVLinearPCMIsNonInterleaved: false,
                    AVLinearPCMIsBigEndianKey: false
                ],
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            self.file = f
        } catch {
            destroyTapAndAggregateLocked()
            throw TapError.fileOpenFailed(error.localizedDescription)
        }

        self.writeFormat = writeFmt
        self.tapFormat = built.tapFormat
        self.capturedSampleRate = built.captureSampleRate
        self.capturedSampleRateSource = built.captureSampleRateSource

        // 3) Spin up the off-realtime writer (ring + drain thread) BEFORE the
        //    IOProc starts producing. ~4 s of mono float headroom; the IOProc
        //    only ever copies into this ring, never touches the disk.
        let ringFrames = max(Int(writeFmt.sampleRate * 4), 48_000)
        let newRing = FloatRingBuffer(capacityFrames: ringFrames)
        self.ring = newRing
        self.scratch = UnsafeMutablePointer<Float>.allocate(capacity: scratchCapacity)
        writerShouldStop.withLock { $0 = false }
        startWriterThread(file: self.file!, writeFormat: writeFmt, ring: newRing)

        // 4) Install IOProc + start the aggregate device.
        do {
            try installIOProcAndStartLocked()
        } catch {
            stopWriterThreadAndDrain()
            self.ring = nil
            self.scratch?.deallocate()
            self.scratch = nil
            file = nil   // finalize/close the just-opened file
            destroyTapAndAggregateLocked()
            throw error
        }

        started = true

        // Prime watchdog timestamps to "now".
        let now = mach_absolute_time()
        lastLoudHostTime.withLock { $0 = now }
        lastCallbackHostTime.withLock { $0 = now }
        installRouteListeners()
        startWatchdog()
    }

    /// Gate writes. Device keeps running, meters keep updating. Thread-safe.
    func setPaused(_ isPaused: Bool) {
        paused.withLock { $0 = isPaused }
    }

    /// Stop the IOProc, destroy the aggregate + tap, finalize the file.
    func stop() -> CaptureResult {
        stopWatchdog()
        removeRouteListeners()

        lock.lock()
        defer { lock.unlock() }

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

        // Drain whatever the IOProc already enqueued, then join the writer so
        // it releases its reference to `file` before we finalize it.
        stopWriterThreadAndDrain()

        if let dropped = ring?.totalDropped, dropped > 0 {
            Self.log.error("desktop tap dropped \(dropped) frames (consumer fell behind)")
        }
        ring = nil
        scratch?.deallocate()
        scratch = nil

        // Finalize the file (setting nil flushes + closes — last reference now).
        file = nil
        writeFormat = nil
        tapFormat = nil

        return CaptureResult(
            firstHostTime: firstHostTime,
            sampleRate: capturedSampleRate,
            frameCount: capturedFrames,
            systemAudio: captureMetadataLocked()
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

        // The IOProc runs on a Core Audio realtime thread. It captures `self` weakly via an
        // unmanaged-free closure: we keep `self` alive for the recording's duration and only tear
        // the proc down (synchronously) before releasing, so a strong capture is safe and avoids
        // per-callback retain traffic.
        var newProcID: AudioDeviceIOProcID?
        let ioBlock: AudioDeviceIOBlock = { [weak self] _, inInputData, inInputTime, _, _ in
            guard let self else { return }
            self.handleIO(inputData: inInputData, inputTime: inInputTime, tapFormat: tapFmt)
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
        tapFormat: AVAudioFormat
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

        // --- Compute RMS for the meter + watchdog (mix of channel 0, cheap). ---
        var rms: Float = 0
        vDSP_rmsqv(firstData, vDSP_Stride(tapFormat.isInterleaved ? channelCount : 1), &rms, n)
        if rms > 0.000_03 { // ~ -90 dBFS; treat anything above as "loud" for the watchdog
            lastLoudHostTime.withLock { $0 = now }
        }
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

        // Record the first sample's host time for cross-stream alignment.
        if firstHostTime == nil {
            firstHostTime = inputTime.pointee.mHostTime
        }

        if channelCount <= 1 {
            // Already mono: enqueue straight from the input buffer.
            ring.write(firstData, count: frameCount)
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
                ring.write(scratch, count: chunk)
                offset += chunk
            }
        }
    }

    // MARK: - Writer thread (drains the ring to disk, off the realtime path)

    /// Start the background consumer that drains `ring` into `file`. The thread holds its own
    /// strong references to `file`/`ring` for its lifetime and exits when `writerShouldStop` is set
    /// AND the ring has been fully drained.
    private func startWriterThread(file: AVAudioFile, writeFormat: AVAudioFormat, ring: FloatRingBuffer) {
        let chunkFrames = 4096
        let thread = Thread { [weak self] in
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: writeFormat,
                frameCapacity: AVAudioFrameCount(chunkFrames)
            ), let dst = buffer.floatChannelData?[0] else { return }

            while true {
                let stopRequested = self?.writerShouldStop.withLock { $0 } ?? true
                let n = ring.read(into: dst, maxCount: chunkFrames)
                if n > 0 {
                    buffer.frameLength = AVAudioFrameCount(n)
                    do {
                        try file.write(from: buffer)
                        self?.capturedFrames += AVAudioFramePosition(n)
                    } catch {
                        self?.onFatalError?(error)
                    }
                } else if stopRequested {
                    break               // empty AND asked to stop -> fully drained
                } else {
                    usleep(5_000)        // 5 ms; the ring holds several seconds of headroom
                }
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

    // MARK: - Watchdog (macOS 26 zero-buffer regression)

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
        // Don't intervene while paused (silence is expected) or mid-rebuild.
        if paused.withLock({ $0 }) { return }

        lock.lock()
        let isRunning = started && !rebuilding
        let outDevice = lock_currentOutputDeviceLocked()
        let config = activeConfig
        lock.unlock()
        guard isRunning else { return }

        // Only rebuild if the system output device is actually doing something — otherwise silence
        // is legitimately silence and a rebuild would be pointless churn.
        guard let outDevice, Self.deviceIsRunningSomewhere(outDevice) else { return }

        let now = mach_absolute_time()
        let lastLoud = lastLoudHostTime.withLock { $0 }
        let elapsedNanos = Self.hostTimeToNanos(now &- lastLoud)
        let elapsedSeconds = Double(elapsedNanos) / 1_000_000_000.0

        if config.tapKind == .global, elapsedSeconds >= fallbackSilenceThreshold {
            lock.lock()
            if activeConfig.tapKind == .global {
                fallbackEvents.append("global_tap_silent_after_\(String(format: "%.1f", elapsedSeconds))s; switching_to_device_bound")
                activeConfig.tapKind = .deviceBound
            }
            lock.unlock()
            rebuildTapAndAggregate(reason: "global_tap_silent_fallback")
            return
        }

        if config.tapKind == .deviceBound, elapsedSeconds >= fallbackSilenceThreshold {
            lock.lock()
            if activeConfig.tapKind == .deviceBound {
                fallbackEvents.append("device_bound_tap_silent_after_\(String(format: "%.1f", elapsedSeconds))s; switching_to_process_mixdown")
                activeConfig.tapKind = .processMixdown
            }
            lock.unlock()
            rebuildTapAndAggregate(reason: "device_bound_tap_silent_fallback")
            return
        }

        if elapsedSeconds >= watchdogSilenceThreshold {
            rebuildTapAndAggregate(reason: "watchdog_silence_rebuild")
            var shouldNotify = false
            lock.lock()
            if activeConfig.tapKind == .processMixdown, !captureFailureNotified {
                captureFailureNotified = true
                shouldNotify = true
            }
            lock.unlock()
            if shouldNotify {
                onCaptureFailed?("Core Audio callbacks are active but system audio samples remain silent.")
            }
        }
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

        // Destroy existing Core Audio objects (leaves `file` untouched).
        destroyTapAndAggregateLocked()

        // Fresh tap UUID for the rebuild.
        tapUUID = UUID()

        do {
            fallbackEvents.append("rebuild_started: \(reason)")
            let built = try buildTapAndAggregateLocked()
            // Keep writing in the original write format; only update the realtime wrap format /
            // sample rate if the tap renegotiated. Note: if the sample rate changed we keep the
            // original write file format (mono float) but the incoming buffers are wrapped with the
            // new tapFormat — AVAudioFile will write whatever frames we hand it, so a rate change
            // mid-file produces a benign tempo seam rather than a crash.
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
            try installIOProcAndStartLocked()
        } catch {
            rebuilding = false
            lock.unlock()
            // Rebuild failed: this is fatal for the desktop stream. Surface it; the mic recording
            // and raw desktop-so-far file remain intact.
            onFatalError?(error)
            return
        }

        // Reset watchdog clocks so we give the fresh tap a fair window before judging it again.
        let now = mach_absolute_time()
        lastLoudHostTime.withLock { $0 = now }
        lastCallbackHostTime.withLock { $0 = now }

        rebuilding = false
        lock.unlock()
    }

    private func installRouteListeners() {
        removeRouteListeners()

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

    private func handleRouteChanged(reason: String) {
        lock.lock()
        let shouldRebuild = started && !rebuilding
        let before = currentDevice
        let after = try? Self.deviceSnapshot(deviceID: Self.outputDevice(role: activeConfig.deviceRole))
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
            systemAudioCaptureFailed: captureFailureNotified,
            lastFailureReason: captureFailureNotified
                ? "Core Audio callbacks are active but system audio samples remain silent."
                : nil
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
