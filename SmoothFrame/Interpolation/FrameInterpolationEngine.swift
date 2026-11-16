import CoreVideo
import Foundation

/// A request to interpolate one intermediate frame between two source frames.
struct InterpolationRequest {
    var previous: CVPixelBuffer
    var current: CVPixelBuffer
    /// 0..<1 — position between previous (0) and current (1).
    var factor: Double
    /// Smoothness 0...1 from the UI; engines may use it to blend motion vs. blend.
    var smoothness: Double
}

enum InterpolationError: Error, LocalizedError {
    case unavailable(String)
    case modelMissing(String)
    case failed(String)
    var errorDescription: String? {
        switch self {
        case .unavailable(let m): return "Engine unavailable: \(m)"
        case .modelMissing(let m): return "Model missing: \(m)"
        case .failed(let m): return "Interpolation failed: \(m)"
        }
    }
}

/// Common protocol for all interpolation engines.
/// Implementations must be safe to call from the render thread.
protocol FrameInterpolationEngine: AnyObject {
    var name: String { get }
    /// Maximum output/input frame-rate ratio this engine can sustain, e.g. 5.0 for 24->120.
    var maxScale: Double { get }
    /// Estimated cost in ms for one interpolated frame at the given resolution.
    func estimatedCostMs(width: Int, height: Int) -> Double
    /// True when the engine can run at this resolution at all.
    func supportsResolution(width: Int, height: Int) -> Bool
    /// Produce the intermediate frame, or throw. Returns nil only if the caller
    /// should fall back to showing the nearest source frame.
    func interpolate(_ request: InterpolationRequest) throws -> CVPixelBuffer?
}

/// Pure-logic helpers shared by engines and unit tests (no Apple-only runtime).
enum FrameRateMath {
    /// Interpolated frames needed between two source frames, e.g. 24->60 = 1.5.
    static func interpolatedPerSourceFrame(sourceFPS: Double, targetFPS: Double) -> Double {
        guard sourceFPS > 0 else { return 0 }
        return targetFPS / sourceFPS - 1
    }
    /// Milliseconds available per output frame, e.g. 1000/180 = 5.55 ms.
    static func frameBudgetMs(targetFPS: Double) -> Double {
        guard targetFPS > 0 else { return 0 }
        return 1000.0 / targetFPS
    }
    /// Factors (0..<1) for the interpolated frames between two source frames
    /// when the count is an integer (e.g. 24->120 gives 0.2/0.4/0.6/0.8).
    /// For non-integer ratios (24->60 = 1.5) the caller uses the phase accumulator
    /// in PlaybackEngine instead; see ARCHITECTURE.md section 4.
    static func factors(count: Int) -> [Double] {
        guard count > 0 else { return [] }
        return (1...count).map { Double($0) / Double(count + 1) }
    }
    /// Validate a target FPS against the supported list.
    static func isSupportedTargetFPS(_ fps: Int) -> Bool {
        [48, 50, 60, 72, 90, 120, 144, 180].contains(fps)
    }
}
