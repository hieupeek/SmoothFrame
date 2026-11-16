import CoreVideo
import Foundation

/// Thread-safe 2-frame ring buffer: holds the previous + current source frame.
/// The AVPlayer output callback writes; the render thread reads. NSLock only —
/// no other shared state between the threads.
/// CVPixelBuffer is reference-counted, so retaining here is safe.
final class FrameRingBuffer {
    private let lock = NSLock()
    private var previous: CVPixelBuffer?
    private var current: CVPixelBuffer?
    private var currentPresentationTime: CMTime = .invalid

    /// Push a newly decoded source frame. The old current becomes previous.
    func push(_ buffer: CVPixelBuffer, at time: CMTime) {
        lock.lock()
        defer { lock.unlock() }
        previous = current
        current = buffer
        currentPresentationTime = time
    }

    /// Snapshot of (previous, current) for interpolation. Either may be nil
    /// at startup (only one frame decoded so far).
    func snapshot() -> (previous: CVPixelBuffer?, current: CVPixelBuffer?, time: CMTime) {
        lock.lock()
        defer { lock.unlock() }
        return (previous, current, currentPresentationTime)
    }

    var hasPair: Bool {
        lock.lock()
        defer { lock.unlock() }
        return previous != nil && current != nil
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        previous = nil
        current = nil
        currentPresentationTime = .invalid
    }
}
