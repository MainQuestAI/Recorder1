import AVFoundation
import CoreAudio
import EventKit
import Foundation

func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw NSError(domain: "RouteCalendarRegression", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

@main struct RouteCalendarRegression {
    @MainActor static func main() async {
        do { try await run() }
        catch { fputs("FAIL \(error.localizedDescription)\n", stderr); exit(1) }
    }
    @MainActor static func run() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Recorder1RouteRegression-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("mic.caf")
        let writer = try AudioTimelineWriter(url: path, sampleRate: 48_000)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let tone = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
        tone.frameLength = 4800
        for i in 0..<4800 { tone.floatChannelData![0][i] = Float(sin(Double(i) * .pi * 2 * 440 / 48_000)) * 0.2 }
        func host(_ seconds: Double) -> UInt64 { AudioConvertNanosToHostTime(UInt64(seconds * 1e9)) }
        try writer.append(tone, hostTime: host(100))
        try writer.append(tone, hostTime: host(100.1))
        // A long hardware outage must not pull all later speech 4.4 seconds forward.
        try writer.append(tone, hostTime: host(107.6))
        try require(writer.insertedSilenceFrames == 355_200, "long gap was truncated instead of preserving 7.4 seconds")
        writer.resume()
        try writer.append(tone, hostTime: host(111.7)) // intentional 4-second pause
        try require(writer.insertedSilenceFrames == 355_200, "intentional pause was inserted as missing audio")
        try require(writer.frameCount == 374_400, "pause/resume timeline is misaligned")
        try writer.append(tone, hostTime: host(111.7)) // duplicate delivery
        try require(writer.frameCount == 374_400, "duplicate samples moved later speech")
        let changed = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
        let lowRate = AVAudioPCMBuffer(pcmFormat: changed, frameCapacity: 2400)!
        lowRate.frameLength = 2400
        lowRate.floatChannelData![0].update(repeating: 0.1, count: 2400)
        try writer.append(lowRate, hostTime: host(111.8))
        writer.close()
        let file = try AVAudioFile(forReading: path)
        try require(abs(Double(file.length) / file.processingFormat.sampleRate - 7.9) < 0.01, "rate change altered the timeline")
        file.framePosition = 364_800 // 7.6 seconds: speech must still start here
        let actual = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4800)!
        try file.read(into: actual)
        let peak = (0..<Int(actual.frameLength)).map { abs(actual.floatChannelData![0][$0]) }.max() ?? 0
        try require(peak > 0.1, "post-gap speech is not at the original timestamp")
        try require(writer.failureReason != nil, "lost audio was accepted as complete after padding")
        let desktopPath = folder.appendingPathComponent("desktop.caf")
        let desktop = try AudioTimelineWriter(url: desktopPath, sampleRate: 48_000)
        desktop.reportGapsAsFailure = false
        try desktop.append(tone, hostTime: host(100), pausedSeconds: 0)
        try desktop.append(tone, hostTime: host(110), pausedSeconds: 0)
        // Four seconds intentionally paused, then audio resumes at the correct position.
        try desktop.append(tone, hostTime: host(114.1), pausedSeconds: 4)
        try desktop.finish(at: host(120), pausedSeconds: 4)
        desktop.close()
        let desktopFile = try AVAudioFile(forReading: desktopPath)
        try require(desktopFile.length == 48_000 * 16, "idle output or trailing silence shortened the system timeline")
        try require(desktop.failureReason == nil, "idle output was incorrectly treated as lost microphone audio")
        let packets = TimestampedAudioRingBuffer()
        try tone.floatChannelData![0].withMemoryRebound(to: Float.self, capacity: 4800) { pointer in
            try require(packets.write(pointer, packet: .init(frames: 4096, hostTime: host(100), sampleRate: 48_000, pausedSeconds: 4)), "packet could not be queued")
        }
        let storage = UnsafeMutablePointer<Float>.allocate(capacity: 4096)
        defer { storage.deallocate() }
        let packet = packets.read(into: storage)
        try require(packet?.hostTime == host(100) && packet?.sampleRate == 48_000 && packet?.pausedSeconds == 4 && abs(storage[100] - tone.floatChannelData![0][100]) < 0.0001,
            "queued packet lost its PCM, clock, rate or pause offset")
        for index in 0..<512 {
            try require(packets.write(tone.floatChannelData![0], packet: .init(frames: 32, hostTime: UInt64(index), sampleRate: 24_000, pausedSeconds: 0)), "packet ring dropped a packet before reaching capacity")
        }
        try require(!packets.write(tone.floatChannelData![0], packet: .init(frames: 32, hostTime: 999, sampleRate: 24_000, pausedSeconds: 0)) && packets.totalDropped == 32,
            "full packet ring did not report dropped audio")
        for index in 0..<512 {
            let packet = packets.read(into: storage)
            try require(packet?.hostTime == UInt64(index) && packet?.frames == 32, "packet ring changed order or corrupted a wrapped packet")
        }
        try require(packets.read(into: storage) == nil, "empty packet ring returned stale audio")
        print("PASS system idle gaps, trailing silence, pause offsets and timestamped packet delivery")
        print("PASS long outage preserves speech timestamp; pause, duplicate delivery, resampling, honest integrity")

        var reads = 0
        var requests = 0
        var auth: EKAuthorizationStatus = .denied
        let now = Date(timeIntervalSince1970: 1_000_000)
        let current = Meeting(id: "current", title: "Current", start: now.addingTimeInterval(-600), end: now.addingTimeInterval(600))
        let access = CalendarAccess(authorization: { auth }, request: { requests += 1; return false }, fetch: { _, _ in reads += 1; return [current] })
        let denied = await access.load(now: now, requestAccess: true)
        try require(denied.state == .denied && reads == 0 && requests == 0, "denied permission queried events or prompted repeatedly")
        auth = .notDetermined
        let pending = await access.load(now: now)
        try require(pending.state == .accessRequired && reads == 0, "unrequested permission looked like an empty calendar")
        let refused = await access.load(now: now, requestAccess: true)
        try require(refused.state == .denied && reads == 0 && requests == 1, "refused request still fetched events")
        auth = .fullAccess
        let loaded = await access.load(now: now)
        try require(loaded.state == .ready && loaded.currentMeeting == current && loaded.meetings == [current] && reads == 1, "list and title did not use a single authorized fetch")
        auth = .restricted
        let restricted = await access.load(now: now)
        try require(restricted.state == .restricted && reads == 1, "restricted calendar was fetched")
        let broken = CalendarAccess(authorization: { .notDetermined }, request: { throw CocoaError(.fileReadUnknown) }, fetch: { _, _ in reads += 1; return [] })
        let failed = await broken.load(now: now, requestAccess: true)
        if case .failed = failed.state {} else { throw CocoaError(.coderInvalidValue) }
        try require(reads == 1, "authorization exception was hidden by querying an empty list")
        print("PASS denied, undecided, refused, restricted, failed authorization; single authorized snapshot")
    }
}
