import Foundation
import Synchronization

/// Preallocated SPSC packets keep timestamps beside PCM. The realtime producer
/// never allocates or writes to disk; the consumer can distinguish a silent gap
/// from queued audio and place each packet at its original time.
final class TimestampedAudioRingBuffer: @unchecked Sendable {
    struct Packet {
        var frames = 0
        var hostTime: UInt64 = 0
        var sampleRate = 0.0
        var pausedSeconds = 0.0
    }
    let packetFrames = 4096
    private let capacity = 512
    private let samples: UnsafeMutablePointer<Float>
    private let packets: UnsafeMutablePointer<Packet>
    private let written = Atomic<Int>(0)
    private let consumed = Atomic<Int>(0)
    private let dropped = Atomic<Int>(0)
    var totalDropped: Int { dropped.load(ordering: .relaxed) }

    init() {
        samples = .allocate(capacity: capacity * packetFrames)
        samples.initialize(repeating: 0, count: capacity * packetFrames)
        packets = .allocate(capacity: capacity)
        packets.initialize(repeating: Packet(), count: capacity)
    }
    deinit {
        samples.deinitialize(count: capacity * packetFrames); samples.deallocate()
        packets.deinitialize(count: capacity); packets.deallocate()
    }
    @discardableResult func write(_ source: UnsafePointer<Float>, packet: Packet) -> Bool {
        let w = written.load(ordering: .relaxed)
        guard packet.frames <= packetFrames, w - consumed.load(ordering: .acquiring) < capacity else {
            dropped.wrappingAdd(packet.frames, ordering: .relaxed); return false
        }
        let slot = w % capacity
        memcpy(samples + slot * packetFrames, source, packet.frames * MemoryLayout<Float>.size)
        packets[slot] = packet
        written.store(w + 1, ordering: .releasing)
        return true
    }
    func read(into destination: UnsafeMutablePointer<Float>) -> Packet? {
        let r = consumed.load(ordering: .relaxed)
        guard r < written.load(ordering: .acquiring) else { return nil }
        let slot = r % capacity
        let packet = packets[slot]
        memcpy(destination, samples + slot * packetFrames, packet.frames * MemoryLayout<Float>.size)
        consumed.store(r + 1, ordering: .releasing)
        return packet
    }
}
