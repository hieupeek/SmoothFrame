import Foundation

/// Live playback statistics, published to the SwiftUI stats overlay.
/// All values are updated from the render thread via MainActor hop in PlaybackEngine.
@MainActor
final class PlaybackStats: ObservableObject {
    @Published var sourceFPS: Double = 0
    @Published var outputFPS: Double = 0
    @Published var frameTimeMs: Double = 0
    @Published var interpolatedFrames: Int = 0
    @Published var droppedFrames: Int = 0
    @Published var engineName: String = "—"
    /// Time spent upscaling the last presented frame (Metal/Core Image), milliseconds.
    @Published var upscaleTimeMs: Double = 0
    /// Actual output (post-upscale) frame size in pixels.
    @Published var outputWidth: Int = 0
    @Published var outputHeight: Int = 0
    /// True when the engine auto-degraded (e.g. 180 -> 120 fps) because the
    /// frame budget was exceeded. Shown prominently in the UI.
    @Published var didDegradeFPS: Bool = false
    @Published var degradeReason: String = ""

    var frameBudgetMs: Double {
        guard outputFPS > 0 else { return 0 }
        return 1000.0 / outputFPS
    }

    func reset() {
        sourceFPS = 0; outputFPS = 0; frameTimeMs = 0
        interpolatedFrames = 0; droppedFrames = 0; engineName = "—"
        upscaleTimeMs = 0; outputWidth = 0; outputHeight = 0
        didDegradeFPS = false; degradeReason = ""
    }
}
