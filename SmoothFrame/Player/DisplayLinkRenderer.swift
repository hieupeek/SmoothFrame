import AVFoundation
import CoreVideo
import Metal
import MetalKit
import SwiftUI

/// MTKView that renders the latest (possibly interpolated + upscaled) frame,
/// driven by CVDisplayLink at the display refresh rate.
/// Order of operations per tick (see ARCHITECTURE.md §1):
///   1. Pull latest source frame pair from the ring buffer.
///   2. Interpolate at SOURCE resolution (cheap; ME at half res).
///   3. Upscale to the output resolution (1440p etc.) — AFTER interpolation.
///   4. Render the MTLTexture aspect-fit.
/// Audio sync: the display time is mapped to item time via the player; if the
/// needed source frame hasn't arrived, hold the previous frame and count a drop.
final class DisplayLinkRenderer: NSObject, MTKViewDelegate {
    var playbackEngine: PlaybackEngine?
    var settings: AppSettings = AppSettings()
    var stats: PlaybackStats?
    var sceneDetector = SceneChangeDetector()
    var upscaler: (any VideoUpscaler)?

    private var displayLink: CVDisplayLink?
    private var metalDevice: MTLDevice?
    private var commandQueue: MTLCommandQueue?
    private var textureCache: CVMetalTextureCache?
    private var currentEngine: (any FrameInterpolationEngine)?
    private var currentEngineChoice: EngineChoice = .auto
    private var lastPresentedBuffer: CVPixelBuffer?
    private var lastFrameTime: CFAbsoluteTime = 0

    /// Called from `MetalVideoView.makeNSView` on the main actor. Marked
    /// `@MainActor` because MTKView's properties (`device`, `delegate`,
    /// `framebufferOnly`, `enableSetNeedsDisplay`, `isPaused`) are
    /// main-actor isolated in the macOS 15.5 SDK (CI run 10).
    @MainActor
    func attach(to view: MTKView) {
        metalDevice = MTLCreateSystemDefaultDevice()
        view.device = metalDevice
        view.delegate = self
        view.framebufferOnly = false
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        if let device = metalDevice {
            commandQueue = device.makeCommandQueue()
            CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
        }
        startDisplayLink(view: view)
    }

    private func startDisplayLink(view: MTKView) {
        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard let link else { return }
        self.displayLink = link
        // CVDisplayLink callback: runs on a high-priority thread, NOT the main thread.
        CVDisplayLinkSetOutputCallback(link, { _, _, _, _, _, userInfo in
            guard let userInfo else { return kCVReturnSuccess }
            let renderer = Unmanaged<DisplayLinkRenderer>.fromOpaque(userInfo).takeUnretainedValue()
            renderer.renderTick()
            return kCVReturnSuccess
        }, Unmanaged.passUnretained(self).toOpaque())
        CVDisplayLinkStart(link)
    }

    func stop() {
        if let displayLink { CVDisplayLinkStop(displayLink) }
    }

    // MARK: - Per-tick pipeline

    private func renderTick() {
        let tickStart = CFAbsoluteTimeGetCurrent()
        guard let engine = playbackEngine,
              let info = engine.videoInfo else { return }
        engine.pullLatestFrame()
        let (prev, curr, _) = engine.ringBuffer.snapshot()
        guard let curr else { return } // Nothing decoded yet.

        // Resolve engine (auto-select once per tick is cheap; cache by choice+size).
        let choice = resolveEngineChoice(for: info)
        if currentEngine == nil || currentEngineChoice != choice {
            currentEngine = EngineRegistry.makeEngine(for: choice) ?? BlendEngine()
            currentEngineChoice = choice
        }

        var toPresent: CVPixelBuffer = curr
        var interpolated = false
        if let prev, let interp = currentEngine {
            if sceneDetector.isSceneChange(curr) {
                engine.resetPhase() // Cut: no interpolation across it.
            } else {
                let factors = engine.factorsAfterSourceFrame(targetFPS: Double(settings.targetFPS))
                if let factor = factors.first {
                    let request = InterpolationRequest(previous: prev, current: curr,
                                                       factor: factor * settings.smoothness,
                                                       smoothness: settings.smoothness)
                    if let made = try? interp.interpolate(request) {
                        toPresent = made
                        interpolated = true
                    }
                }
            }
        }

        // Upscale AFTER interpolation, at the output resolution.
        var upscaleMs = 0.0
        if let target = settings.outputResolution.targetHeight,
           target != info.height,
           let upscaler {
            let scale = settings.outputResolution.scaleFactor(fromHeight: info.height)
            let outW = Int(Double(info.width) * scale)
            let outH = target
            let t0 = CFAbsoluteTimeGetCurrent()
            if let up = try? upscaler.upscale(toPresent, toWidth: outW, height: outH) {
                toPresent = up
            }
            upscaleMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        }

        lastPresentedBuffer = toPresent
        let elapsedMs = (CFAbsoluteTimeGetCurrent() - tickStart) * 1000

        // Stats + auto-degrade (hop to MainActor).
        let fps = Double(settings.targetFPS)
        Task { @MainActor [weak self] in
            guard let self, let stats = self.stats else { return }
            stats.outputFPS = fps
            stats.sourceFPS = engine.sourceFPS
            stats.frameTimeMs = elapsedMs
            stats.upscaleTimeMs = upscaleMs
            stats.outputWidth = CVPixelBufferGetWidth(toPresent)
            stats.outputHeight = CVPixelBufferGetHeight(toPresent)
            stats.engineName = self.currentEngine?.name ?? "—"
            if interpolated { stats.interpolatedFrames += 1 }
            if let degraded = engine.noteFrameTime(elapsedMs, targetFPS: self.settings.targetFPS) {
                stats.didDegradeFPS = true
                stats.degradeReason = "Frame time \(String(format: "%.1f", elapsedMs)) ms exceeded the "
                    + "\(String(format: "%.2f", FrameRateMath.frameBudgetMs(targetFPS: Double(self.settings.targetFPS)))) ms budget — "
                    + "auto-degraded to \(degraded) fps."
                self.settings.targetFPS = degraded
            }
        }
        lastFrameTime = tickStart
        _ = lastFrameTime
    }

    private func resolveEngineChoice(for info: VideoInfo) -> EngineChoice {
        if settings.engine != .auto { return settings.engine }
        let sel = EngineRegistry.autoSelect(sourceFPS: info.sourceFPS, targetFPS: settings.targetFPS,
                                            width: info.width, height: info.height)
        return sel.engine
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let buffer = lastPresentedBuffer,
              let drawable = view.currentDrawable,
              let device = metalDevice,
              let queue = commandQueue,
              let cache = textureCache else { return }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        var cvTexture: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, buffer, nil,
                                                       .bgra8Unorm, width, height, 0, &cvTexture) == kCVReturnSuccess,
              let cvTexture,
              let texture = CVMetalTextureGetTexture(cvTexture),
              let commandBuffer = queue.makeCommandBuffer(),
              let pass = view.currentRenderPassDescriptor else { return }
        // TODO(Phase 2): proper aspect-fit. This blit copy assumes the drawable
        // is the same size as the texture; if the MTKView is resized to a
        // different aspect the copy can fail or stretch. Replace with a
        // fullscreen-quad vertex/fragment pass that letterboxes correctly.
        guard let encoder = commandBuffer.makeBlitCommandEncoder() else { return }
        encoder.copy(from: texture, sourceSlice: 0, sourceLevel: 0,
                     sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                     sourceSize: MTLSize(width: width, height: height, depth: 1),
                     to: drawable.texture, destinationSlice: 0, destinationLevel: 0,
                     destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
        _ = device
    }
}

/// SwiftUI wrapper for the MTKView.
struct MetalVideoView: NSViewRepresentable {
    var renderer: DisplayLinkRenderer

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        renderer.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {}
}
