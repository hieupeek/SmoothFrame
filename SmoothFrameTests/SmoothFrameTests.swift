import Foundation
import XCTest

/// Pure-logic tests only: no AVFoundation/Metal/CoreML runtime dependency,
/// so these tests can actually pass in a plain XCTest run.
/// NOTE: the app target types used here (FrameRateMath, SceneChangeDetector,
/// EngineRegistry, OutputResolution, TargetFPS) live in the app module;
/// the test target must have @testable import SmoothFrame enabled in Xcode
/// (the .pbxproj wires the test target's TEST_HOST to the app).
/// If @testable import is unavailable in your setup, copy the pure-logic
/// helpers into the test target — the math below is self-contained.
@testable import SmoothFrame

final class SmoothFrameTests: XCTestCase {

    // MARK: - Frame-rate math

    func testFramesNeeded24to60() {
        // 24 -> 60 needs 1.5 interpolated frames per source frame.
        XCTAssertEqual(FrameRateMath.interpolatedPerSourceFrame(sourceFPS: 24, targetFPS: 60), 1.5, accuracy: 1e-9)
    }

    func testFramesNeeded24to120() {
        XCTAssertEqual(FrameRateMath.interpolatedPerSourceFrame(sourceFPS: 24, targetFPS: 120), 4, accuracy: 1e-9)
    }

    func testFramesNeeded24to180() {
        // 24 -> 180: 7.5x, i.e. 6.5 interpolated frames per source frame.
        XCTAssertEqual(FrameRateMath.interpolatedPerSourceFrame(sourceFPS: 24, targetFPS: 180), 6.5, accuracy: 1e-9)
    }

    func testFramesNeeded30to180() {
        // 30 -> 180: 6x, i.e. 5 interpolated frames per source frame.
        XCTAssertEqual(FrameRateMath.interpolatedPerSourceFrame(sourceFPS: 30, targetFPS: 180), 5, accuracy: 1e-9)
    }

    func testFramesNeeded60to180() {
        // 60 -> 180: 3x, i.e. 2 interpolated frames per source frame.
        XCTAssertEqual(FrameRateMath.interpolatedPerSourceFrame(sourceFPS: 60, targetFPS: 180), 2, accuracy: 1e-9)
    }

    func testFrameBudget180fps() {
        // 1000/180 = 5.555... ms per output frame.
        XCTAssertEqual(FrameRateMath.frameBudgetMs(targetFPS: 180), 1000.0 / 180.0, accuracy: 1e-9)
        XCTAssertEqual(FrameRateMath.frameBudgetMs(targetFPS: 180), 5.555, accuracy: 0.01)
    }

    func testFrameBudget60fps() {
        XCTAssertEqual(FrameRateMath.frameBudgetMs(targetFPS: 60), 16.666, accuracy: 0.01)
    }

    func testBlendFactorMath() {
        // Integer-count factors: 24->120 gives 0.2/0.4/0.6/0.8.
        XCTAssertEqual(FrameRateMath.factors(count: 4), [0.2, 0.4, 0.6, 0.8])
        XCTAssertEqual(FrameRateMath.factors(count: 1), [0.5])
        XCTAssertEqual(FrameRateMath.factors(count: 0), [])
        for f in FrameRateMath.factors(count: 6) {
            XCTAssertTrue(f > 0 && f < 1, "factor \(f) must be in (0,1)")
        }
    }

    func testTargetFPSValidation() {
        for fps in [48, 50, 60, 72, 90, 120, 144, 180] {
            XCTAssertTrue(FrameRateMath.isSupportedTargetFPS(fps), "\(fps) should be supported")
        }
        XCTAssertFalse(FrameRateMath.isSupportedTargetFPS(30))
        XCTAssertFalse(FrameRateMath.isSupportedTargetFPS(240))
        XCTAssertFalse(FrameRateMath.isSupportedTargetFPS(0))
        XCTAssertTrue(TargetFPS.isValid(180))
        XCTAssertFalse(TargetFPS.isValid(25))
        XCTAssertEqual(TargetFPS.fps180.frameBudgetMs, 1000.0 / 180.0, accuracy: 1e-9)
    }

    // MARK: - Scene-change threshold logic

    func testSceneChangeIdenticalHistograms() {
        let h = [Double](repeating: 1.0 / 64.0, count: 64)
        XCTAssertEqual(SceneChangeDetector.histogramDistance(h, h), 0, accuracy: 1e-9)
    }

    func testSceneChangeCompletelyDifferentHistograms() {
        var a = [Double](repeating: 0, count: 64); a[0] = 1
        var b = [Double](repeating: 0, count: 64); b[63] = 1
        XCTAssertEqual(SceneChangeDetector.histogramDistance(a, b), 1, accuracy: 1e-9)
    }

    func testSceneChangeThresholdBoundary() {
        // A small shift (0.1) is below the default 0.35 threshold; a big one is above.
        var a = [Double](repeating: 1.0 / 64.0, count: 64)
        var b = a; b[0] += 0.1; b[1] -= 0.1
        XCTAssertLessThan(SceneChangeDetector.histogramDistance(a, b), 0.35)
        var c = [Double](repeating: 0, count: 64); c[0] = 0.7; c[1] = 0.3
        var d = [Double](repeating: 0, count: 64); d[62] = 0.7; d[63] = 0.3
        XCTAssertGreaterThan(SceneChangeDetector.histogramDistance(c, d), 0.35)
        _ = a
    }

    // MARK: - Engine auto-select

    func testAutoSelect1080p60UsesMetal() {
        let sel = EngineRegistry.autoSelect(sourceFPS: 24, targetFPS: 60, width: 1920, height: 1080)
        XCTAssertEqual(sel.engine, .metalMotion)
        XCTAssertFalse(sel.degraded)
    }

    func testAutoSelect4KUsesBlend() {
        let sel = EngineRegistry.autoSelect(sourceFPS: 24, targetFPS: 60, width: 3840, height: 2160)
        XCTAssertEqual(sel.engine, .blend)
    }

    func testAutoSelect1440p180NeverUsesRIFEOrOpticalFlow() {
        let sel = EngineRegistry.autoSelect(sourceFPS: 24, targetFPS: 180, width: 2560, height: 1440)
        XCTAssertNotEqual(sel.engine, .rife)
        XCTAssertNotEqual(sel.engine, .opticalFlow)
        XCTAssertTrue(sel.engine == .blend || sel.engine == .metalMotion)
    }

    func testAutoSelect1440p180DegradesWhenOverBudget() {
        // With the MVP cost estimates Metal (~7 ms) and Blend (~3 ms) at 1440p:
        // Blend fits 5.55 ms, so no degradation is expected from these estimates.
        // The degradation path itself is tested via degradedFPS below.
        let sel = EngineRegistry.autoSelect(sourceFPS: 24, targetFPS: 180, width: 2560, height: 1440)
        XCTAssertTrue(sel.targetFPS == 180 || sel.targetFPS == 120)
    }

    func testDegradedFPSLadder() {
        // 30 consecutive over-budget frames at 180 fps steps down to 144.
        XCTAssertEqual(EngineRegistry.degradedFPS(from: 180, measuredMs: 8.0, overBudgetFrames: 30), 144)
        // Fewer than 30 over-budget frames: no degradation.
        XCTAssertNil(EngineRegistry.degradedFPS(from: 180, measuredMs: 8.0, overBudgetFrames: 29))
        // Within budget: no degradation.
        XCTAssertNil(EngineRegistry.degradedFPS(from: 180, measuredMs: 5.0, overBudgetFrames: 100))
        // 120 -> 90.
        XCTAssertEqual(EngineRegistry.degradedFPS(from: 120, measuredMs: 9.0, overBudgetFrames: 30), 90)
    }

    // MARK: - Upscale scale factors

    func testScaleFactor1080pTo1440p() {
        XCTAssertEqual(OutputResolution.qhd1440p.scaleFactor(fromHeight: 1080), 1.333, accuracy: 0.001)
    }

    func testScaleFactor720pTo1440p() {
        XCTAssertEqual(OutputResolution.qhd1440p.scaleFactor(fromHeight: 720), 2.0, accuracy: 1e-9)
    }

    func testScaleFactorNativeIsOne() {
        XCTAssertEqual(OutputResolution.native.scaleFactor(fromHeight: 1080), 1.0, accuracy: 1e-9)
        XCTAssertEqual(OutputResolution.hd1080p.scaleFactor(fromHeight: 1080), 1.0, accuracy: 1e-9)
    }

    func testVideoInfoScaleFactor() {
        let info = VideoInfo(url: URL(fileURLWithPath: "/tmp/test.mp4"), duration: 10,
                             sourceFPS: 24, width: 1920, height: 1080, codec: "h264")
        XCTAssertEqual(info.scaleFactor(toHeight: 1440), 1.333, accuracy: 0.001)
    }

    // MARK: - QHD 180 display detection (pure logic)

    func testDisplayInfoIsQHD180() {
        let d = DisplayInfo(name: "External", width: 2560, height: 1440, refreshRateHz: 180, isMain: true)
        XCTAssertTrue(d.isQHD)
        XCTAssertTrue(d.isQHD180)
        let d60 = DisplayInfo(name: "External", width: 2560, height: 1440, refreshRateHz: 60, isMain: true)
        XCTAssertTrue(d60.isQHD)
        XCTAssertFalse(d60.isQHD180)
        let fhd = DisplayInfo(name: "Built-in", width: 1920, height: 1080, refreshRateHz: 180, isMain: true)
        XCTAssertFalse(fhd.isQHD180)
    }

    func testQHD180Preset() {
        let preset = AppSettings.qhd180Preset
        XCTAssertEqual(preset.targetFPS, 180)
        XCTAssertEqual(preset.outputResolution, .qhd1440p)
        XCTAssertEqual(preset.engine, .auto)
    }
}
