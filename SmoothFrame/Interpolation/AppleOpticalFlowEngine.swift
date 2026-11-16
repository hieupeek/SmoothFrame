import AVFoundation
import CoreVideo
import Foundation

/// System frame-rate conversion engine.
///
/// HONESTY NOTE — read before wiring Phase 2:
/// macOS does not expose a public, documented VideoToolbox call named
/// "convert this frame to 180 fps with optical flow" whose exact signature the
/// author could verify without Xcode on hand. Inventing a function name
/// (e.g. a fake `VTFrameRateConversionSession`) would produce code that looks
/// real but does not compile. So this engine is a clearly-marked wrapper:
///
///  * TODAY (MVP): it delegates to `BlendEngine` and reports itself as
///    `.unavailable` with a precise message, so the UI/registry never silently
///    pretends to do optical flow.
///  * PHASE 2 (on a Mac with Xcode 16): wire the real system path. The most
///    likely candidates to verify in the macOS 14 SDK headers are:
///      - `VTPixelTransferSession` (VideoToolbox) — pixel format / scaling
///        transfer, NOT frame interpolation; check whether the installed
///        SDK exposes any frame-rate conversion session type.
///      - `AVVideoComposition` with a custom `AVVideoCompositing` compositor
///        driven by `AVAssetReader` — the supported way to do custom frame
///        generation inside AVFoundation.
///      - Vision framework `VNDetectOpticalFlowRequest` (available macOS 12+)
///        for flow vectors, then warp in Metal — this is the realistic
///        implementation path if no VT session exists.
///  * The wrapper keeps the `FrameInterpolationEngine` contract so Phase 2 is
///    a drop-in replacement: flip `isWired` to true and implement
///    `interpolateWithSystemAPI(_:)`.
///
/// Do NOT "fix" this file by guessing an API name. Verify in the SDK first.
@available(macOS 14, *)
final class AppleOpticalFlowEngine: FrameInterpolationEngine {
    var name: String { "Apple Optical Flow (system)" }
    var maxScale: Double { 5.0 }

    /// Set to true only when a real system API has been wired and tested (Phase 2).
    static let isWired = false

    private let blendFallback = BlendEngine()

    func estimatedCostMs(width: Int, height: Int) -> Double {
        // System path would be GPU/ANE-accelerated; placeholder estimate.
        Double(width * height) / Double(1920 * 1080) * 3.0
    }

    func supportsResolution(width: Int, height: Int) -> Bool { width > 0 && height > 0 }

    func interpolate(_ request: InterpolationRequest) throws -> CVPixelBuffer? {
        guard Self.isWired else {
            throw InterpolationError.unavailable(
                "System optical-flow frame-rate conversion is not wired yet (Phase 2). " +
                "See AppleOpticalFlowEngine.swift for the SDK APIs to verify. Falling back is handled by the caller.")
        }
        // Phase 2: replace this line with the real system call.
        return try blendFallback.interpolate(request)
    }

    // MARK: - Phase 2 wiring point
    // TODO(Phase 2): implement interpolateWithSystemAPI(_:) after verifying the
    // macOS 14 SDK. Candidate: Vision VNDetectOpticalFlowRequest -> Metal warp.
    // Until then this method intentionally does not exist — no fake API calls.
}
