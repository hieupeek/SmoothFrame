import CoreImage
import CoreVideo
import Foundation
import Metal
import MetalPerformanceShaders

/// Real-time upscaler based on Metal Performance Shaders.
///
/// - `.fast`: MPSImageBilinearScale (cheapest).
/// - `.balanced`: MPSImageLanczosScale (better sharpness, still cheap).
/// - `.quality`: Lanczos + a light Metal sharpen kernel (see Motion.metal `sharpen`).
///
/// Fallback: Core Image `CILanczosScaleTransform` when MPS/Metal is unavailable.
///
/// HONEST NOTE: this is classical (non-AI) upscaling — Lanczos/bilinear plus
/// sharpening. It is NOT AI super-resolution. It makes 1080p fill a 1440p screen
/// cleanly, but it cannot invent detail the way Real-ESRGAN or a neural
/// upscaler can. See the "Future: neural upscaling" note at the bottom of
/// this file for what a Real-ESRGAN / CoreML upscaler would need.
final class MetalUpscaler: VideoUpscaler {
    let quality: UpscaleQuality
    var name: String {
        switch quality {
        case .fast: return "Metal Bilinear (fast)"
        case .balanced: return "Metal Lanczos (balanced)"
        case .quality: return "Metal Lanczos + Sharpen (quality)"
        }
    }
    var maxScale: Double { 4.0 }

    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private let sharpenPipeline: MTLComputePipelineState?
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    init(quality: UpscaleQuality = .balanced) {
        self.quality = quality
        self.device = MTLCreateSystemDefaultDevice()
        self.commandQueue = device?.makeCommandQueue()
        if let device, let library = device.makeDefaultLibrary(),
           let fn = library.makeFunction(name: "sharpen") {
            self.sharpenPipeline = try? device.makeComputePipelineState(function: fn)
        } else {
            self.sharpenPipeline = nil
        }
    }

    func upscale(_ pixelBuffer: CVPixelBuffer, toWidth targetWidth: Int, height targetHeight: Int) throws -> CVPixelBuffer {
        let srcW = CVPixelBufferGetWidth(pixelBuffer)
        let srcH = CVPixelBufferGetHeight(pixelBuffer)
        guard srcW > 0, srcH > 0, targetWidth > 0, targetHeight > 0 else {
            throw UpscalerError.scaleFailed("invalid dimensions")
        }
        if srcW == targetWidth && srcH == targetHeight { return pixelBuffer }

        // Prefer Metal/MPS; fall back to Core Image if no Metal device.
        if let device, let queue = commandQueue {
            if let out = try? upscaleWithMPS(pixelBuffer, device: device, queue: queue,
                                             toWidth: targetWidth, height: targetHeight) {
                return out
            }
            // MPS failed (e.g. pixel format) — fall through to Core Image.
        }
        return try upscaleWithCoreImage(pixelBuffer, toWidth: targetWidth, height: targetHeight)
    }

    // MARK: - MPS path

    private func upscaleWithMPS(_ pixelBuffer: CVPixelBuffer, device: MTLDevice,
                                queue: MTLCommandQueue,
                                toWidth targetWidth: Int, height targetHeight: Int) throws -> CVPixelBuffer {
        var format = kCVPixelFormatType_32BGRA
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: format,
            kCVPixelBufferWidthKey as String: targetWidth,
            kCVPixelBufferHeightKey as String: targetHeight,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        var outBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, targetWidth, targetHeight,
                                         format, attrs as CFDictionary, &outBuffer)
        guard status == kCVReturnSuccess, let output = outBuffer else {
            throw UpscalerError.scaleFailed("could not allocate output pixel buffer (\(status))")
        }
        guard let srcTexture = makeTexture(from: pixelBuffer, device: device),
              let dstTexture = makeTexture(from: output, device: device),
              let commandBuffer = queue.makeCommandBuffer() else {
            throw UpscalerError.metalUnavailable
        }
        let scale: MPSImageScale
        switch quality {
        case .fast:
            scale = MPSImageBilinearScale(device: device)
        case .balanced, .quality:
            scale = MPSImageLanczosScale(device: device)
        }
        scale.encode(commandBuffer: commandBuffer, sourceTexture: srcTexture, destinationTexture: dstTexture)
        if quality == .quality, let sharpen = sharpenPipeline {
            encodeSharpen(texture: dstTexture, commandBuffer: commandBuffer, pipeline: sharpen)
        }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return output
    }

    private func encodeSharpen(texture: MTLTexture, commandBuffer: MTLCommandBuffer,
                               pipeline: MTLComputePipelineState) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(texture, index: 0)
        encoder.setTexture(texture, index: 1)
        let w = pipeline.threadExecutionWidth
        let threadsPerGroup = MTLSize(width: w, height: 1, depth: 1)
        let groups = MTLSize(width: (texture.width + w - 1) / w, height: texture.height, depth: 1)
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()
    }

    private func makeTexture(from pixelBuffer: CVPixelBuffer, device: MTLDevice) -> MTLTexture? {
        var textureCache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache) == kCVReturnSuccess,
              let cache = textureCache else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, nil, .bgra8Unorm, width, height, 0, &cvTexture)
        guard status == kCVReturnSuccess, let cvTexture else { return nil }
        return CVMetalTextureGetTexture(cvTexture)
    }

    // MARK: - Core Image fallback

    private func upscaleWithCoreImage(_ pixelBuffer: CVPixelBuffer,
                                      toWidth targetWidth: Int, height targetHeight: Int) throws -> CVPixelBuffer {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let scaleX = Double(targetWidth) / Double(max(CVPixelBufferGetWidth(pixelBuffer), 1))
        let scaleY = Double(targetHeight) / Double(max(CVPixelBufferGetHeight(pixelBuffer), 1))
        guard let filter = CIFilter(name: "CILanczosScaleTransform") else {
            throw UpscalerError.scaleFailed("CILanczosScaleTransform unavailable")
        }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(scaleX, forKey: kCIInputScaleKey)
        filter.setValue(Double(min(scaleX, scaleY)), forKey: kCIInputAspectRatioKey)
        guard let outputImage = filter.outputImage else {
            throw UpscalerError.scaleFailed("Core Image produced no output")
        }
        var outBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: targetWidth,
            kCVPixelBufferHeightKey as String: targetHeight,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, targetWidth, targetHeight,
                                         kCVPixelFormatType_32BGRA, attrs as CFDictionary, &outBuffer)
        guard status == kCVReturnSuccess, let output = outBuffer else {
            throw UpscalerError.scaleFailed("could not allocate output pixel buffer (\(status))")
        }
        ciContext.render(outputImage, to: output)
        return output
    }
}

// MARK: - Future: neural upscaling (stub / design note, NOT implemented)
//
// A Real-ESRGAN / CoreML neural upscaler would be a separate type conforming to
// `VideoUpscaler`, e.g. `CoreMLUpscaler`, that:
//   1. Loads a user-supplied `.mlmodelc` (Real-ESRGAN x4plus converted to CoreML)
//      from ~/Library/Application Support/SmoothFrame/Models/ — same folder as RIFE.
//   2. Runs the model on the Neural Engine / GPU via MLModel prediction.
//   3. Costs far more than Lanczos (likely 20-50 ms/frame at 1080p on M1), so it
//      would be export-only or low-fps, NOT real-time 1440p180.
// No fake implementation is provided here on purpose: shipping a stub that
// pretends to do neural upscaling would be misleading. This is a Phase 3 item.
// Reference: Real-ESRGAN (Xintao Wang et al.), BSD-3-Clause; CoreML conversion
// via coremltools. Model files are NOT bundled with this repo.
