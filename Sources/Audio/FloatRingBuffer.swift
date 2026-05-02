import Foundation

/// Minimal thread-safe single-writer/single-reader ring buffer of Float32 samples.
///
/// We use this on the capture side to bridge variable-sized mic buffers to the
/// fixed 20 ms (960-sample) frames Opus expects.
final class FloatRingBuffer {
    private var storage: [Float]
    private var writeIndex = 0
    private var readIndex = 0
    private var _count = 0
    private let lock = NSLock()

    init(capacity: Int) {
        self.storage = Array(repeating: 0, count: capacity)
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return _count
    }

    func write(_ samples: UnsafePointer<Float>, count: Int) {
        lock.lock(); defer { lock.unlock() }
        let cap = storage.count
        for i in 0..<count {
            storage[writeIndex] = samples[i]
            writeIndex = (writeIndex + 1) % cap
            if _count < cap {
                _count += 1
            } else {
                // Overflow — drop oldest sample.
                readIndex = (readIndex + 1) % cap
            }
        }
    }

    /// Reads `count` samples into `dest` if available. Returns true on success.
    func read(into dest: UnsafeMutablePointer<Float>, count: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard _count >= count else { return false }
        let cap = storage.count
        for i in 0..<count {
            dest[i] = storage[readIndex]
            readIndex = (readIndex + 1) % cap
        }
        _count -= count
        return true
    }
}
