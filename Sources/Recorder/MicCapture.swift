import Foundation
@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import CoreMedia
import os

/// Input-only capture: changing the system playback route must not tear down a
/// microphone engine's output unit or negotiate Bluetooth playback formats.
final class MicCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    enum MicError: LocalizedError {
        case inputDeviceUnavailable(String)
        case invalidInputFormat
        var errorDescription: String? {
            switch self {
            case .inputDeviceUnavailable(let uid): return "Selected microphone is unavailable: \(uid)"
            case .invalidInputFormat: return "Microphone returned an unusable audio format."
            }
        }
    }

    var onLevelDB: ((Float) -> Void)?
    var onFatalError: ((Error) -> Void)?
    var onEvent: ((String) -> Void)?
    var onInputChanged: ((AudioInputDeviceInfo) -> Void)?

    private let controlQueue = DispatchQueue(label: "com.dingcheng.Recorder1.mic-control")
    private let samplesQueue = DispatchQueue(label: "com.dingcheng.Recorder1.mic-samples", qos: .userInitiated)
    private let state = OSAllocatedUnfairLock<(running: Bool, device: AudioInputDeviceInfo?, lastCallback: UInt64, clock: CMClock?, callbacks: Int)>(initialState: (false, nil, 0, nil, 0))
    private var session: AVCaptureSession?
    private var output: AVCaptureAudioDataOutput?
    private var observers: [NSObjectProtocol] = []
    private var inputListener: AudioObjectPropertyListenerBlock?
    private var preferredUID: String?
    private var watchdog: DispatchSourceTimer?
    private var recoveryWork: DispatchWorkItem?
    private var recoveryAttempts = 0
    private var configuredAt: UInt64 = 0
    private var callbacksAtRecovery = 0
    private var reportedStall = false
    // Accessed only on samplesQueue (including stop's final drain).
    private var writer: AudioTimelineWriter?
    private var paused = false
    private var failureReason: String?
    private var events: [String] = []

    var activeInputDevice: AudioInputDeviceInfo? { state.withLock { $0.device } }

    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    func start(writingTo url: URL, preferredInputDeviceUID: String? = nil) throws {
        try controlQueue.sync {
            guard !state.withLock({ $0.running }) else { return }
            preferredUID = preferredInputDeviceUID.flatMap { $0.isEmpty ? nil : $0 }
            let device = try resolveDevice()
            let newWriter = try AudioTimelineWriter(url: url, sampleRate: device.sampleRate)
            samplesQueue.sync {
                writer = newWriter; paused = false; failureReason = nil; events = []
                newWriter.onGap = { [weak self] gap in
                    self?.recordEvent(String(format: "capture_gap seconds=%.6f", gap))
                    if gap > 1, let self, let reason = self.writer?.failureReason {
                        self.onFatalError?(NSError(domain: "Microphone", code: 3, userInfo: [NSLocalizedDescriptionKey: reason]))
                    }
                }
            }
            state.withLock { $0 = (true, device, mach_absolute_time(), nil, 0) }
            do {
                try configureSession(device: device)
                installInputListener()
                startWatchdog()
            } catch {
                stopSession()
                state.withLock { $0.running = false }
                samplesQueue.sync { writer?.close(); writer = nil }
                throw error
            }
        }
    }

    private func resolveDevice() throws -> AudioInputDeviceInfo {
        let device = preferredUID.flatMap { uid in AudioDeviceCatalog.inputDevices().first { $0.uid == uid } }
            ?? (preferredUID == nil ? AudioDeviceCatalog.defaultInputDevice() : nil)
        guard let device, device.sampleRate > 0 else {
            throw MicError.inputDeviceUnavailable(preferredUID ?? "system default")
        }
        return device
    }

    private func configureSession(device: AudioInputDeviceInfo) throws {
        stopSession()
        guard let captureDevice = AVCaptureDevice(uniqueID: device.uid) else {
            throw NSError(domain: "Microphone", code: 2, userInfo: [NSLocalizedDescriptionKey: "Microphone is not available for capture: \(device.name)"])
        }
        let next = AVCaptureSession()
        next.beginConfiguration()
        let input = try AVCaptureDeviceInput(device: captureDevice)
        let nextOutput = AVCaptureAudioDataOutput()
        nextOutput.audioSettings = [AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsNonInterleaved: false]
        guard next.canAddInput(input), next.canAddOutput(nextOutput) else {
            next.commitConfiguration()
            throw CocoaError(.featureUnsupported)
        }
        next.addInput(input)
        next.addOutput(nextOutput)
        nextOutput.setSampleBufferDelegate(self, queue: samplesQueue)
        next.commitConfiguration()
        session = next; output = nextOutput
        observers.append(NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: next, queue: nil) { [weak self] note in
            let error = (note.userInfo?[AVCaptureSessionErrorKey] as? Error)?.localizedDescription ?? "Microphone session stopped"
            self?.controlQueue.async { [weak self] in self?.scheduleRecovery(reason: error) }
        })
        next.startRunning()
        guard next.isRunning else { throw CocoaError(.fileReadUnknown) }
        configuredAt = mach_absolute_time()
        callbacksAtRecovery = state.withLock { $0.device = device; $0.clock = next.synchronizationClock; return $0.callbacks }
        onInputChanged?(device)
        samplesQueue.async { [weak self] in self?.recordEvent("input_started uid=\(device.uid) sample_rate=\(device.sampleRate)") }
    }

    private func stopSession() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        output?.setSampleBufferDelegate(nil, queue: nil)
        session?.stopRunning()
        samplesQueue.sync {}
        state.withLock { $0.clock = nil }
        session = nil; output = nil
    }

    private func scheduleRecovery(reason: String) {
        guard state.withLock({ $0.running }), recoveryWork == nil else { return }
        samplesQueue.async { [weak self] in self?.recordEvent("recovery_requested: \(reason)") }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.recoveryWork = nil
            guard self.state.withLock({ $0.running }) else { return }
            self.recoveryAttempts += 1
            do { try self.configureSession(device: self.resolveDevice()) }
            catch {
                if self.recoveryAttempts < 3 { self.scheduleRecovery(reason: error.localizedDescription) }
                else { self.reportFailure(error) }
            }
        }
        recoveryWork = work
        controlQueue.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func reportFailure(_ error: Error) {
        samplesQueue.async { [weak self] in
            self?.failureReason = error.localizedDescription
            self?.recordEvent("capture_failed: \(error.localizedDescription)")
        }
        onFatalError?(error)
    }

    private func installInputListener() {
        guard preferredUID == nil else { return }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.state.withLock({ $0.running }),
                  let device = AudioDeviceCatalog.defaultInputDevice(), device.uid != self.activeInputDevice?.uid else { return }
            self.recoveryAttempts = 0
            self.scheduleRecovery(reason: "default_input_device_changed")
        }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, controlQueue, block) == noErr { inputListener = block }
    }

    private func startWatchdog() {
        recoveryAttempts = 0
        let timer = DispatchSource.makeTimerSource(queue: controlQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let snapshot = self.state.withLock { $0 }
            guard snapshot.running else { return }
            let age = Double(AudioConvertHostTimeToNanos(mach_absolute_time() - max(snapshot.lastCallback, self.configuredAt))) / 1e9
            if snapshot.callbacks > self.callbacksAtRecovery && age < 2 {
                self.recoveryAttempts = 0; self.reportedStall = false; return
            }
            guard age > 5 else { return }
            if self.recoveryAttempts < 3 { self.scheduleRecovery(reason: "callback_stall") }
            else if !self.reportedStall {
                self.reportedStall = true
                self.reportFailure(NSError(domain: "Microphone", code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "Microphone callbacks stopped after three recovery attempts."]))
            }
        }
        watchdog = timer; timer.resume()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard state.withLock({ $0.running }) else { return }
        state.withLock { $0.lastCallback = mach_absolute_time(); $0.callbacks += 1 }
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer) else { reportSampleFailure(MicError.invalidInputFormat); return }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))) else { return }
        buffer.frameLength = buffer.frameCapacity
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(buffer.frameLength), into: buffer.mutableAudioBufferList)
        guard status == noErr else { reportSampleFailure(CocoaError(.fileReadCorruptFile)); return }
        onLevelDB?(RMSMeter.dBFS(buffer))
        guard !paused else { return }
        guard let clock = state.withLock({ $0.clock }) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let hostPTS = CMSyncConvertTime(pts, from: clock, to: CMClockGetHostTimeClock())
        guard hostPTS.isNumeric else { reportSampleFailure(CocoaError(.fileReadCorruptFile)); return }
        let host = CMClockConvertHostTimeToSystemUnits(hostPTS)
        do { try writer?.append(buffer, hostTime: host) }
        catch { reportSampleFailure(error) }
    }

    private func reportSampleFailure(_ error: Error) {
        guard failureReason == nil else { return }
        failureReason = error.localizedDescription
        recordEvent("write_failed: \(error.localizedDescription)")
        onFatalError?(error)
    }

    private func recordEvent(_ message: String) {
        let event = "\(ISO8601DateFormatter().string(from: Date())) \(message)"
        events.append(event); onEvent?(event)
    }

    func setPaused(_ value: Bool) {
        samplesQueue.sync {
            if paused && !value { writer?.resume() }
            paused = value
        }
    }

    func stop() -> CaptureResult {
        controlQueue.sync {
            recoveryWork?.cancel(); recoveryWork = nil
            watchdog?.cancel(); watchdog = nil
            if let inputListener {
                var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                    mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
                AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, controlQueue, inputListener)
            }
            inputListener = nil
            stopSession()
            // Drain callbacks already enqueued before clearing running or finalizing CAF.
            let result = samplesQueue.sync {
                let result = CaptureResult(firstHostTime: writer?.firstHostTime,
                    sampleRate: writer?.format.sampleRate ?? 0, frameCount: writer?.frameCount ?? 0,
                    failureReason: failureReason ?? writer?.failureReason,
                    microphone: MicrophoneCaptureMetadata(insertedSilenceFrames: writer?.insertedSilenceFrames ?? 0, events: events, firstHostTime: writer?.firstHostTime))
                writer?.close(); writer = nil
                return result
            }
            state.withLock { $0.running = false; $0.device = nil }
            return result
        }
    }
}
