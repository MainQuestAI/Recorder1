import Accelerate
import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

final class AudioProbeOutput: NSObject, SCStreamOutput {
    private let lock = NSLock()
    private(set) var callbacks = 0
    private(set) var maxRMS: Float = 0
    private(set) var firstNonZeroCallback: Int?

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio, sampleBuffer.isValid else { return }

        var blockBuffer: CMBlockBuffer?
        var audioBufferList = AudioBufferList()
        var size = 0
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &size,
            bufferListOut: &audioBufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return }

        let buffers = UnsafeMutableAudioBufferListPointer(&audioBufferList)
        guard let first = buffers.first,
              let data = first.mData?.assumingMemoryBound(to: Float.self) else {
            return
        }
        let channelCount = max(Int(first.mNumberChannels), 1)
        let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.stride * channelCount)
        guard frames > 0 else { return }

        var rms: Float = 0
        vDSP_rmsqv(data, vDSP_Stride(channelCount), &rms, vDSP_Length(frames))

        lock.lock()
        callbacks += 1
        maxRMS = max(maxRMS, rms)
        if rms > 0.000_03, firstNonZeroCallback == nil {
            firstNonZeroCallback = callbacks
        }
        lock.unlock()
    }

    func snapshot() -> (callbacks: Int, maxRMS: Float, firstNonZero: Int?) {
        lock.lock()
        defer { lock.unlock() }
        return (callbacks, maxRMS, firstNonZeroCallback)
    }
}

func db(_ value: Float) -> String {
    let db = value > 0 ? max(-120, 20 * log10(value)) : -120
    return String(format: "%.1f", db)
}

@main
struct SCKAudioProbe {
    static func main() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            guard let display = content.displays.first else {
                throw NSError(domain: "SCKAudioProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: "no display found"])
            }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.width = 2
            configuration.height = 2
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            configuration.capturesAudio = true
            configuration.excludesCurrentProcessAudio = false
            configuration.sampleRate = 48_000
            configuration.channelCount = 2

            let output = AudioProbeOutput()
            let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: DispatchQueue(label: "sck.screen.probe"))
            try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: DispatchQueue(label: "sck.audio.probe"))
            try await stream.startCapture()

            let say = Process()
            say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            say.arguments = [
                "Recorder1 Screen Capture Kit audio probe. This sentence should produce non zero system audio samples."
            ]
            try? say.run()
            try await Task.sleep(nanoseconds: 5_000_000_000)
            try await stream.stopCapture()
            if say.isRunning { say.terminate() }

            let result = output.snapshot()
            print("callbacks: \(result.callbacks)")
            print("max_rms_db: \(db(result.maxRMS))")
            print("first_nonzero_callback: \(result.firstNonZero.map(String.init) ?? "none")")
            if result.maxRMS > 0.000_03 {
                print("PASS ScreenCaptureKit system audio produced non-zero samples")
            } else {
                print("FAIL ScreenCaptureKit system audio stayed silent")
                exit(1)
            }
        } catch {
            fputs("FAIL \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
