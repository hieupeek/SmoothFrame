import AVFoundation
import CoreVideo
import Foundation

/// Offline export — the SVPcode equivalent: read a source file, interpolate
/// frames, write a high-frame-rate MP4. Audio is passed through untouched.
/// Supports up to 1440p180 HEVC output, with an explicit warning: files are
/// very large and export is slow (interpolation + upscale per frame, CPU/GPU
/// bound). Export runs on a background queue and is cancellable.
///
/// UNTESTED on real hardware.
/// - Note: `@unchecked Sendable` — the mutable state is the `cancelled` flag
///   plus the two callback properties below, set on the main actor
///   (`cancel()` / `export()`) and read from the single detached export task.
///   Swift 6 cannot verify that, so the class opts out the same way
///   `PlaybackEngine` does with `nonisolated(unsafe)`. Real thread safety
///   still needs verification on a Mac.
final class OfflineExporter: @unchecked Sendable {
    struct Options {
        var targetFPS: Int = 60
        var outputResolution: OutputResolution = .native
        var codec: AVVideoCodecType = .h264
        /// HEVC (.hevc) is recommended for 1440p180 — much smaller than H.264.
        var useHEVCForHighRes: Bool = true
    }

    /// Human-readable warning for heavy export settings, shown in the UI.
    static func heavyExportWarning(for options: Options, source: VideoInfo) -> String? {
        if options.targetFPS >= 180 || options.outputResolution == .qhd1440p || options.outputResolution == .uhd2160p {
            let outH = options.outputResolution.targetHeight ?? source.height
            let frames = Int(source.duration * Double(options.targetFPS))
            return "Export nặng: \(outH)p @ \(options.targetFPS) fps, ~\(frames) khung hình. "
                + "File đầu ra rất lớn và xuất chậm (có thể chậm hơn thời gian thực nhiều lần trên MacBook Air). "
                + "Nên dùng HEVC để giảm dung lượng."
        }
        return nil
    }

    private var cancelled = false
    func cancel() { cancelled = true }

    /// Callbacks for the in-flight export, stored as `nonisolated(unsafe)` —
    /// the same pattern as `PlaybackEngine`'s properties (which CI runs 6–7
    /// proved the compiler accepts): the exporter is created fresh per
    /// export (`ContentView.startExport`), so one export owns one instance.
    /// Written on the calling thread before the detached task starts; read
    /// only from that task (completion via `MainActor.run`).
    nonisolated(unsafe) private var progressHandler: ((Double) -> Void)?
    nonisolated(unsafe) private var completionHandler: ((Result<URL, Error>) -> Void)?

    /// Export `sourceURL` to `destinationURL`. Progress 0...1 via callback.
    /// Calls completion on the main actor.
    func export(sourceURL: URL, destinationURL: URL, options: Options,
                progress: @escaping (Double) -> Void,
                completion: @escaping (Result<URL, Error>) -> Void) {
        cancelled = false
        progressHandler = progress
        completionHandler = completion
        Task.detached(priority: .userInitiated) { [self] in
            do {
                let asset = AVAsset(url: sourceURL)
                guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
                    throw NSError(domain: "SmoothFrame", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "No video track."])
                }
                let fps = Double(try await videoTrack.load(.nominalFrameRate))
                let size = try await videoTrack.load(.naturalSize)
                let duration = try await asset.load(.duration)
                let info = VideoInfo(url: sourceURL, duration: duration.seconds, sourceFPS: fps,
                                     width: Int(size.width), height: Int(size.height), codec: "unknown")

                let outHeight = options.outputResolution.targetHeight ?? info.height
                let scale = options.outputResolution.scaleFactor(fromHeight: info.height)
                let outWidth = Int(Double(info.width) * scale)
                let codec: AVVideoCodecType = (options.useHEVCForHighRes && outHeight >= 1440) ? .hevc : options.codec

                let reader = try AVAssetReader(asset: asset)
                let readerOutput = AVAssetReaderTrackOutput(
                    track: videoTrack,
                    outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
                reader.add(readerOutput)

                let writer = try AVAssetWriter(outputURL: destinationURL, fileType: .mp4)
                let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
                    AVVideoCodecKey: codec,
                    AVVideoWidthKey: outWidth,
                    AVVideoHeightKey: outHeight,
                ])
                writerInput.expectsMediaDataInRealTime = false
                let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: writerInput,
                                                                   sourcePixelBufferAttributes: nil)
                writer.add(writerInput)
                writer.startWriting()
                writer.startSession(atSourceTime: .zero)
                reader.startReading()

                let engine: any FrameInterpolationEngine = BlendEngine() // Export uses Blend for determinism/speed.
                let upscaler: (any VideoUpscaler)? = (outHeight != info.height)
                    ? MetalUpscaler(quality: .balanced) : nil
                var prev: CVPixelBuffer?
                var presentationTime = CMTime.zero
                let frameDuration = CMTime(value: 1, timescale: CMTimeScale(options.targetFPS))
                var frameIndex = 0
                let totalFrames = Int(info.duration * Double(options.targetFPS))

                while reader.status == .reading, !cancelled {
                    guard let sample = readerOutput.copyNextSampleBuffer(),
                          let buffer = CMSampleBufferGetImageBuffer(sample) else { break }
                    let curr = buffer
                    if let prev {
                        // Emit interpolated frames between prev and curr.
                        let count = max(0, Int(round(Double(options.targetFPS) / max(fps, 1))) - 1)
                        for k in 1...max(count, 1) where k <= count {
                            let factor = Double(k) / Double(count + 1)
                            let request = InterpolationRequest(previous: prev, current: curr,
                                                               factor: factor, smoothness: 1.0)
                            if let made = try? engine.interpolate(request) {
                                self.appendFrame(made, at: presentationTime, adaptor: adaptor,
                                                 input: writerInput, upscaler: upscaler,
                                                 width: outWidth, height: outHeight)
                                presentationTime = CMTimeAdd(presentationTime, frameDuration)
                                frameIndex += 1
                                progressHandler?(Double(frameIndex) / Double(max(totalFrames, 1)))
                            }
                        }
                    }
                    appendFrame(curr, at: presentationTime, adaptor: adaptor, input: writerInput,
                                upscaler: upscaler, width: outWidth, height: outHeight)
                    presentationTime = CMTimeAdd(presentationTime, frameDuration)
                    frameIndex += 1
                    progressHandler?(Double(frameIndex) / Double(max(totalFrames, 1)))
                    prev = curr
                    if cancelled { break }
                }

                writerInput.markAsFinished()
                if cancelled {
                    try? FileManager.default.removeItem(at: destinationURL)
                    await MainActor.run {
                        completionHandler?(.failure(NSError(domain: "SmoothFrame", code: 3,
                                                    userInfo: [NSLocalizedDescriptionKey: "Export cancelled."])))
                    }
                    return
                }
                await writer.finishWriting()
                if writer.status == .completed {
                    await MainActor.run { completionHandler?(.success(destinationURL)) }
                } else {
                    let err = writer.error ?? NSError(domain: "SmoothFrame", code: 4,
                                                      userInfo: [NSLocalizedDescriptionKey: "Export failed."])
                    await MainActor.run { completionHandler?(.failure(err)) }
                }
            } catch {
                await MainActor.run { completionHandler?(.failure(error)) }
            }
        }
    }

    private func appendFrame(_ buffer: CVPixelBuffer, at time: CMTime,
                             adaptor: AVAssetWriterInputPixelBufferAdaptor,
                             input: AVAssetWriterInput,
                             upscaler: (any VideoUpscaler)?,
                             width: Int, height: Int) {
        var toWrite = buffer
        if let upscaler, (CVPixelBufferGetWidth(buffer) != width || CVPixelBufferGetHeight(buffer) != height) {
            if let up = try? upscaler.upscale(buffer, toWidth: width, height: height) { toWrite = up }
        }
        while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.01) }
        adaptor.append(toWrite, withPresentationTime: time)
    }
}
