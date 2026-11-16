import CoreVideo
import Foundation
import Metal

/// Motion-estimation / motion-compensation (MEMC) engine using Metal compute.
/// Pipeline (see ARCHITECTURE.md §6):
///   1. `blockMatch` kernel: 16x16 block matching with a +/-16 px search radius
///      on half-resolution luma, producing forward + backward motion vectors.
///   2. `warpBlend` kernel: warp both frames to the intermediate time `t` and
///      blend, with an occlusion test (forward + backward vectors must cancel).
/// Falls back to BlendEngine when Metal is unavailable or a step fails.
/// UNTESTED on real hardware — the kernels are written against the public Metal
/// shading language, but performance/quality must be measured on a Mac.
final class MetalMotionEngine: FrameInterpolationEngine {
    var name: String { "Metal Motion (MEMC)" }
    var maxScale: Double { 7.5 }

    /// Motion estimation runs at this scale of the source (MacLC-style:
    /// estimate at low res, upsample vectors). Keeps 1440p180 feasible.
    var motionEstimationScale: Double = 0.5

    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private let blockMatchPipeline: MTLComputePipelineState?
    private let warpBlendPipeline: MTLComputePipelineState?
    private let blendFallback = BlendEngine()

    init(motionEstimationScale: Double = 0.5) {
        self.motionEstimationScale = motionEstimationScale
        self.device = MTLCreateSystemDefaultDevice()
        self.commandQueue = device?.makeCommandQueue()
        var blockMatch: MTLComputePipelineState?
        var warpBlend: MTLComputePipelineState?
        if let device, let library = device.makeDefaultLibrary() {
            if let fn = library.makeFunction(name: "blockMatch") {
                blockMatch = try? device.makeComputePipelineState(function: fn)
            }
            if let fn = library.makeFunction(name: "warpBlend") {
                warpBlend = try? device.makeComputePipelineState(function: fn)
            }
        }
        self.blockMatchPipeline = blockMatch
        self.warpBlendPipeline = warpBlend
    }

    var isAvailable: Bool {
        device != nil && blockMatchPipeline != nil && warpBlendPipeline != nil
    }

    func estimatedCostMs(width: Int, height: Int) -> Double {
        // ME at half res dominates; ~4 ms at 1080p, ~7 ms at 1440p (estimates, UNTESTED).
        let pixels = Double(width * height)
        return pixels / Double(1920 * 1080) * 4.0
    }

    func supportsResolution(width: Int, height: Int) -> Bool {
        isAvailable && width >= 64 && height >= 64
    }

    func interpolate(_ request: InterpolationRequest) throws -> CVPixelBuffer? {
        guard isAvailable, let device, let queue = commandQueue,
              let blockMatch = blockMatchPipeline, let warpBlend = warpBlendPipeline else {
            // Graceful fallback: never fail playback because Metal is missing.
            return try blendFallback.interpolate(request)
        }
        let width = CVPixelBufferGetWidth(request.previous)
        let height = CVPixelBufferGetHeight(request.previous)
        guard width == CVPixelBufferGetWidth(request.current),
              height == CVPixelBufferGetHeight(request.current) else {
            throw InterpolationError.failed("frame size mismatch")
        }
        guard let prevTex = texture(from: request.previous, device: device),
              let currTex = texture(from: request.current, device: device) else {
            return try blendFallback.interpolate(request)
        }
        // Motion-vector buffer: one float2 per 16x16 block, forward + backward.
        let blocksX = (width + 15) / 16
        let blocksY = (height + 15) / 16
        guard let mvBuffer = device.makeBuffer(length: blocksX * blocksY * MemoryLayout<SIMD2<Float>>.size * 2,
                                               options: .storageModeShared),
              let commandBuffer = queue.makeCommandBuffer() else {
            return try blendFallback.interpolate(request)
        }
        // Pass 1: block matching.
        if let encoder = commandBuffer.makeComputeCommandEncoder() {
            encoder.setComputePipelineState(blockMatch)
            encoder.setTexture(prevTex, index: 0)
            encoder.setTexture(currTex, index: 1)
            encoder.setBuffer(mvBuffer, offset: 0, index: 0)
            var dims = SIMD4<Int32>(Int32(width), Int32(height), Int32(blocksX), Int32(blocksY))
            encoder.setBytes(&dims, length: MemoryLayout<SIMD4<Int32>>.size, index: 1)
            let w = blockMatch.threadExecutionWidth
            encoder.dispatchThreadgroups(MTLSize(width: blocksX, height: blocksY, depth: 1),
                                         threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
            _ = w
            encoder.endEncoding()
        }
        // Pass 2: warp + blend into a fresh output texture.
        var output: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                         kCVPixelFormatType_32BGRA, attrs as CFDictionary, &output)
        guard status == kCVReturnSuccess, let out = output,
              let outTex = texture(from: out, device: device) else {
            return try blendFallback.interpolate(request)
        }
        if let encoder = commandBuffer.makeComputeCommandEncoder() {
            encoder.setComputePipelineState(warpBlend)
            encoder.setTexture(prevTex, index: 0)
            encoder.setTexture(currTex, index: 1)
            encoder.setTexture(outTex, index: 2)
            encoder.setBuffer(mvBuffer, offset: 0, index: 0)
            var params = SIMD4<Float>(Float(request.factor), Float(width), Float(height), Float(blocksX))
            encoder.setBytes(&params, length: MemoryLayout<SIMD4<Float>>.size, index: 1)
            let w = warpBlend.threadExecutionWidth
            let h = warpBlend.maxTotalThreadsPerThreadgroup / w
            encoder.dispatchThreadgroups(MTLSize(width: (width + 15) / 16, height: (height + 15) / 16, depth: 1),
                                         threadsPerThreadgroup: MTLSize(width: w, height: max(1, h), depth: 1))
            encoder.endEncoding()
        }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let error = commandBuffer.error {
            // Don't crash playback on a GPU error; fall back to blend.
            print("SmoothFrame: MetalMotion failed (\(error)), falling back to Blend")
            return try blendFallback.interpolate(request)
        }
        return out
    }

    private func texture(from pixelBuffer: CVPixelBuffer, device: MTLDevice) -> MTLTexture? {
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, nil, .bgra8Unorm, width, height, 0, &cvTexture)
        guard status == kCVReturnSuccess, let cvTexture else { return nil }
        return CVMetalTextureGetTexture(cvTexture)
    }
}
