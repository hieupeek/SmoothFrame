import AppKit
import CoreGraphics
import Foundation

/// Detected display capabilities, used to suggest presets (e.g. "Màn 2K 180Hz").
struct DisplayInfo: Equatable {
    var name: String
    var width: Int
    var height: Int
    var refreshRateHz: Double   // 0 if unknown
    var isMain: Bool

    var isQHD: Bool { width == 2560 && height == 1440 }
    var isQHD180: Bool { isQHD && refreshRateHz >= 179 }
    var label: String {
        let hz = refreshRateHz > 0 ? String(format: "%.0f Hz", refreshRateHz) : "?"
        return "\(name): \(width)×\(height) @ \(hz)"
    }
}

enum DisplayDetector {
    /// All attached displays, main screen first.
    static func detectAll() -> [DisplayInfo] {
        var result: [DisplayInfo] = []
        for screen in NSScreen.screens {
            let frame = screen.frame
            // NSScreen frame is in points; convert with backingScaleFactor for pixels.
            let scale = screen.backingScaleFactor
            let width = Int(frame.width * scale)
            let height = Int(frame.height * scale)
            // NOTE: NSScreen has no public refresh-rate API; resolved below via CGDisplayMode.
            let hz: Double = 0
            let name = screen.localizedName
            result.append(DisplayInfo(name: name, width: width, height: height,
                                      refreshRateHz: Double(hz), isMain: screen == NSScreen.main))
        }
        // Refresh rate via CGDisplayMode (the reliable source on macOS).
        if result.allSatisfy({ $0.refreshRateHz <= 0 }) {
            result = result.enumerated().map { index, info in
                var copy = info
                if index < CGDisplayCountMaxFallback() {
                    // `CGDisplayModeGetRefreshRate` is obsolete since Swift 3;
                    // use the `CGDisplayMode.refreshRate` property instead.
                    // 0 means "unknown", matching DisplayInfo.refreshRateHz.
                    copy.refreshRateHz = currentMode(ofDisplayAt: index)?.refreshRate ?? 0
                }
                return copy
            }
        }
        return result
    }

    static func mainDisplay() -> DisplayInfo? {
        detectAll().first(where: { $0.isMain }) ?? detectAll().first
    }

    /// True when the main display is exactly 2560x1440 @ ~180 Hz.
    static func mainIsQHD180() -> Bool { mainDisplay()?.isQHD180 ?? false }

    /// Suggested settings for the detected main display, or nil if nothing special.
    /// QHD 180 Hz -> the one-tap "Màn 2K 180Hz" preset (1440p + 180 fps + Auto engine).
    static func suggestedPreset() -> AppSettings? {
        guard let display = mainDisplay() else { return nil }
        if display.isQHD180 { return AppSettings.qhd180Preset }
        if display.refreshRateHz >= 119 {
            // ProMotion 120 Hz display: 120 fps, native resolution.
            var s = AppSettings()
            s.targetFPS = 120
            return s
        }
        return nil
    }

    // MARK: - Private helpers

    private static func CGDisplayCountMaxFallback() -> Int { 8 }

    private static func currentMode(ofDisplayAt index: Int) -> CGDisplayMode? {
        var onlineDisplays = [CGDirectDisplayID](repeating: 0, count: 8)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(8, &onlineDisplays, &count) == .success,
              index < Int(count) else { return nil }
        return CGDisplayCopyDisplayMode(onlineDisplays[index])
    }
}
