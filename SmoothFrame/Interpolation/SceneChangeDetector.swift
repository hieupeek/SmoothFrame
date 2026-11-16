import CoreVideo
import Foundation

/// Detects scene cuts via a luma histogram difference.
/// If diff > threshold, the caller must NOT interpolate across the cut —
/// show the source frame and reset the phase accumulator.
/// Pure-logic part (histogram diff) is unit-tested; pixel sampling is not.
final class SceneChangeDetector {
    var threshold: Double
    private var previousHistogram: [Double]?

    init(threshold: Double = 0.35) { self.threshold = threshold }

    /// Histogram distance 0...1 between two 64-bin normalised histograms.
    static func histogramDistance(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 1 }
        var sum = 0.0
        for i in a.indices { sum += abs(a[i] - b[i]) }
        return min(1, sum / 2)
    }

    /// Returns true if `pixelBuffer` starts a new scene vs. the previous frame.
    /// Samples luma on a coarse grid (every 8th pixel) for speed.
    func isSceneChange(_ pixelBuffer: CVPixelBuffer) -> Bool {
        let histogram = lumaHistogram(pixelBuffer)
        defer { previousHistogram = histogram }
        guard let prev = previousHistogram else { return false }
        return Self.histogramDistance(prev, histogram) > threshold
    }

    func reset() { previousHistogram = nil }

    private func lumaHistogram(_ pixelBuffer: CVPixelBuffer) -> [Double] {
        var bins = [Double](repeating: 0, count: 64)
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return bins }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        // Assumes 32BGRA (B,G,R,A). Luma approx = 0.299R + 0.587G + 0.114B.
        var total = 0.0
        var y = 0
        while y < height {
            var x = 0
            while x < width {
                let offset = y * bytesPerRow + x * 4
                let b = Double(ptr[offset]), g = Double(ptr[offset + 1]), r = Double(ptr[offset + 2])
                let luma = 0.299 * r + 0.587 * g + 0.114 * b
                bins[min(63, Int(luma / 4))] += 1
                total += 1
                x += 8
            }
            y += 8
        }
        guard total > 0 else { return bins }
        return bins.map { $0 / total }
    }
}
