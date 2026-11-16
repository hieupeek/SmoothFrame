import Foundation

/// Basic metadata about the currently opened video.
struct VideoInfo: Equatable {
    var url: URL
    var duration: Double          // seconds
    var sourceFPS: Double         // e.g. 24, 25, 30, 60
    var width: Int
    var height: Int
    var codec: String             // best-effort guess from track format descriptions, e.g. "h264"

    var displayName: String { url.lastPathComponent }
    var resolutionLabel: String { "\(width)×\(height)" }

    /// Scale factor needed to reach a target output height (e.g. 1080 -> 1440 = 1.333x).
    func scaleFactor(toHeight targetHeight: Int) -> Double {
        guard height > 0, targetHeight > 0 else { return 1 }
        return Double(targetHeight) / Double(height)
    }
}
