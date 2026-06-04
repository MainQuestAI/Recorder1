import Foundation
import Synchronization

/// Lock-free single-producer / single-consumer ring buffer of `Float` samples.
///
/// The Core Audio process-tap IOProc (a hard realtime thread) is the SOLE
/// producer; a dedicated background writer thread is the SOLE consumer. The
/// producer path does no allocation, no file I/O, and takes no locks — just a
/// `memcpy` plus two atomic index updates with acquire/release ordering. This
/// is what keeps the realtime callback under its ~10 ms deadline; doing the
/// `AVAudioFile.write` (or any malloc) directly in the IOProc overran the
/// deadline and tore the desktop stream at every IO-buffer boundary.
///
/// Indices are monotonically increasing absolute counts; the storage position
/// is `index % capacity`. `Int` is 64-bit, so wraparound of the counters
/// themselves is not a practical concern.
final class FloatRingBuffer: @unchecked Sendable {

    private let storage: UnsafeMutablePointer<Float>
    private let capacity: Int

    private let writeIndex = Atomic<Int>(0)
    private let readIndex = Atomic<Int>(0)
    private let droppedFrames = Atomic<Int>(0)

    init(capacityFrames: Int) {
        precondition(capacityFrames > 0)
        capacity = capacityFrames
        storage = UnsafeMutablePointer<Float>.allocate(capacity: capacityFrames)
        storage.initialize(repeating: 0, count: capacityFrames)
    }

    deinit {
        storage.deinitialize(count: capacity)
        storage.deallocate()
    }

    /// Frames the producer had to drop because the consumer fell behind.
    /// Expected to stay 0 in practice (the buffer holds several seconds).
    var totalDropped: Int { droppedFrames.load(ordering: .relaxed) }

    /// Producer side (realtime thread). Copies `count` frames from `src`. If
    /// there isn't room for the whole chunk it drops it (recording the loss)
    /// rather than tearing it — a partial write would itself be a glitch.
    @discardableResult
    func write(_ src: UnsafePointer<Float>, count: Int) -> Bool {
        guard count > 0 else { return true }
        let w = writeIndex.load(ordering: .relaxed)
        let r = readIndex.load(ordering: .acquiring)
        let free = capacity - (w - r)
        if count > free {
            droppedFrames.wrappingAdd(count, ordering: .relaxed)
            return false
        }
        let start = w % capacity
        let first = min(count, capacity - start)
        memcpy(storage + start, src, first * MemoryLayout<Float>.stride)
        if first < count {
            memcpy(storage, src + first, (count - first) * MemoryLayout<Float>.stride)
        }
        // Release: the data writes above must be visible before the index bump.
        writeIndex.store(w + count, ordering: .releasing)
        return true
    }

    /// Consumer side (writer thread). Copies up to `maxCount` frames into `dst`
    /// and returns how many were copied (0 when empty).
    func read(into dst: UnsafeMutablePointer<Float>, maxCount: Int) -> Int {
        let r = readIndex.load(ordering: .relaxed)
        // Acquire: pair with the producer's release so we see its sample writes.
        let w = writeIndex.load(ordering: .acquiring)
        let available = w - r
        if available <= 0 { return 0 }
        let count = min(available, maxCount)
        let start = r % capacity
        let first = min(count, capacity - start)
        memcpy(dst, storage + start, first * MemoryLayout<Float>.stride)
        if first < count {
            memcpy(dst + first, storage, (count - first) * MemoryLayout<Float>.stride)
        }
        readIndex.store(r + count, ordering: .releasing)
        return count
    }
}
