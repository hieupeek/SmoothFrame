import Foundation

/// Persistent user settings. Stored via AppStorage in ContentView / SmoothFrameApp.
/// NOTE: targetFPS default 60; the "Màn 2K 180Hz" preset sets 180 + .qhd1440p.
enum PlaybackProfile: String, CaseIterable, Identifiable {
    case film = "Film"
    case anime = "Anime"
    case sports = "Sports"
    var id: String { rawValue }

    /// Default smoothness (0...1) and scene-change threshold per profile.
    var smoothness: Double {
        switch self {
        case .film: return 0.7
        case .anime: return 0.5   // Anime: keep line art crisp, less aggressive interpolation.
        case .sports: return 1.0
        }
    }
    var sceneThreshold: Double {
        switch self {
        case .film: return 0.35
        case .anime: return 0.45  // Anime has abrupt background changes within a scene.
        case .sports: return 0.30
        }
    }
}

enum EngineChoice: String, CaseIterable, Identifiable {
    case auto = "Auto"
    case blend = "Blend"
    case metalMotion = "Metal Motion"
    case opticalFlow = "Optical Flow"
    case rife = "RIFE (CoreML)"
    var id: String { rawValue }
}

/// Target output frame rates. 180 fps is for 180 Hz displays (e.g. QHD 180 Hz).
/// Frame budget at 180 fps is only 1000/180 ≈ 5.55 ms — very demanding, see ARCHITECTURE.md.
enum TargetFPS: Int, CaseIterable, Identifiable {
    case fps48 = 48, fps50 = 50, fps60 = 60, fps72 = 72
    case fps90 = 90, fps120 = 120, fps144 = 144, fps180 = 180
    var id: Int { rawValue }
    var label: String { "\(rawValue) fps" }
    /// Milliseconds available per output frame.
    var frameBudgetMs: Double { 1000.0 / Double(rawValue) }
    static func isValid(_ value: Int) -> Bool { TargetFPS(rawValue: value) != nil }
}

struct AppSettings {
    var targetFPS: Int = 60
    var engine: EngineChoice = .auto
    var smoothness: Double = 0.7
    var sceneThreshold: Double = 0.35
    var showStats: Bool = false
    var profile: PlaybackProfile = .film
    var outputResolution: OutputResolution = .native
    var upscaleQuality: UpscaleQuality = .balanced

    /// One-tap preset for a QHD 2560x1440 @ 180 Hz display.
    /// 1440p + 180 fps + automatic engine. Honest note: on a MacBook Air this
    /// preset will very likely fall back to 120 fps (see EngineRegistry).
    static var qhd180Preset: AppSettings {
        AppSettings(targetFPS: 180, engine: .auto, smoothness: 0.8,
                    sceneThreshold: 0.35, showStats: true, profile: .film,
                    outputResolution: .qhd1440p, upscaleQuality: .balanced)
    }
}
