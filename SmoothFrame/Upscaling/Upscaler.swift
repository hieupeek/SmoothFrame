import CoreVideo
import Foundation

/// Output resolution choices. "2K" in this app means QHD 2560x1440.
/// 4K (UHD 3840x2160) is offered for export / future use; real-time 4K upscaling
/// + interpolation on a MacBook Air is NOT expected to hold 60 fps.
enum OutputResolution: String, CaseIterable, Identifiable {
    case native = "Native"
    case hd1080p = "1080p (1920×1080)"
    case qhd1440p = "2K QHD (2560×1440)"
    case uhd2160p = "4K UHD (3840×2160)"
    var id: String { rawValue }

    /// Target size preserving the source aspect ratio is computed by the caller;
    /// these are the reference heights.
    var targetHeight: Int? {
        switch self {
        case .native: return nil
        case .hd1080p: return 1080
        case .qhd1440p: return 1440
        case .uhd2160p: return 2160
        }
    }

    /// Scale factor from a source height, e.g. 1080 -> 1440 = 1.333x, 720 -> 1440 = 2.0x.
    func scaleFactor(fromHeight sourceHeight: Int) -> Double {
        guard let target = targetHeight, sourceHeight > 0 else { return 1 }
        return Double(target) / Double(sourceHeight)
    }
}

enum UpscaleQuality: String, CaseIterable, Identifiable {
    case fast = "Fast"
    case balanced = "Balanced"
    case quality = "Quality"
    var id: String { rawValue }
}

enum UpscalerError: Error, LocalizedError {
    case unsupportedPixelFormat
    case metalUnavailable
    case scaleFailed(String)
    var errorDescription: String? {
        switch self {
        case .unsupportedPixelFormat: return "Pixel format not supported for upscaling."
        case .metalUnavailable: return "Metal device unavailable."
        case .scaleFailed(let why): return "Upscale failed: \(why)"
        }
    }
}

/// Protocol for video upscalers. Implementations must be thread-safe for calls
/// from the render thread and must not retain the input pixel buffer.
protocol VideoUpscaler: AnyObject {
    var name: String { get }
    /// Largest scale factor this upscaler can handle in real time (approx).
    var maxScale: Double { get }
    /// Upscale `pixelBuffer` to `targetWidth` x `targetHeight`.
    /// Returns a new CVPixelBuffer, or throws.
    func upscale(_ pixelBuffer: CVPixelBuffer, toWidth targetWidth: Int, height targetHeight: Int) throws -> CVPixelBuffer
}
