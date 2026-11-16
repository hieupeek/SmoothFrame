import AVFoundation
import CoreVideo
import Foundation

/// Owns AVPlayer + AVPlayerItemVideoOutput and pumps decoded frames into the
/// ring buffer. Audio is untouched (AVPlayer plays it directly).
/// Presentation is driven by CVDisplayLink in DisplayLinkRenderer; this class
/// only decodes, tracks source FPS, and keeps the phase accumulator for
/// non-integer ratios (e.g. 24 -> 60 needs 1.5 interpolated frames per source
/// frame — see ARCHITECTURE.md §4).
///
/// UNTESTED on real hardware: AVPlayerItemVideoOutput delegate behaviour and
/// CVDisplayLink timing must be verified on a Mac.
final class PlaybackEngine: NSObject {
    let player = AVPlayer()
    private var videoOutput: AVPlayerItemVideoOutput?
    private let outputQueue = DispatchQueue(label: "com.hieupeek.SmoothFrame.videoOutput")
    private(set) var ringBuffer = FrameRingBuffer()
    private(set) var videoInfo: VideoInfo?
    private(set) var sourceFPS: Double = 0

    /// Phase accumulator for non-integer target/source ratios.
    private var phase: Double = 0
    /// Number of consecutive frames whose measured time exceeded the budget.
    private(set) var overBudgetFrames: Int = 0

    var onNewFrame: (() -> Void)?
    var onError: ((Error) -> Void)?

    /// Open a video file. Calls completion on the main actor with VideoInfo or an error.
    func open(url: URL, completion: @escaping (Result<VideoInfo, Error>) -> Void) {
        let asset = AVAsset(url: url)
        Task {
            do {
                let tracks = try await asset.loadTracks(withMediaType: .video)
                guard let track = tracks.first else {
                    throw NSError(domain: "SmoothFrame", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "No video track found."])
                }
                let fps = try await track.load(.nominalFrameRate)
                let size = try await track.load(.naturalSize)
                let duration = try await asset.load(.duration)
                let info = VideoInfo(url: url, duration: duration.seconds, sourceFPS: Double(fps),
                                     width: Int(size.width), height: Int(size.height),
                                     codec: Self.codecGuess(for: track))
                await MainActor.run {
                    self.videoInfo = info
                    self.sourceFPS = Double(fps)
                    self.setupPlayer(with: asset)
                    completion(.success(info))
                }
            } catch {
                await MainActor.run { completion(.failure(error)) }
            }
        }
    }

    private static func codecGuess(for track: AVAssetTrack) -> String {
        // Best effort from format descriptions; "unknown" is honest when unreadable.
        guard let desc = track.formatDescriptions.first as? CMFormatDescription,
              let ext = CMFormatDescriptionGetExtension(desc, extensionKey: kCMFormatDescriptionExtension_FormatName) as? String else {
            return "unknown"
        }
        return ext
    }

    private func setupPlayer(with asset: AVAsset) {
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: attrs)
        output.setDelegate(self, queue: outputQueue)
        self.videoOutput = output
        let item = AVPlayerItem(asset: asset)
        item.add(output)
        ringBuffer.clear()
        phase = 0
        player.replaceCurrentItem(with: item)
    }

    func play() { player.play() }
    func pause() { player.pause() }
    func togglePlayPause() { player.rate == 0 ? play() : pause() }
    func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        ringBuffer.clear()
        phase = 0
    }

    /// Advance the phase accumulator by one source frame and return the
    /// interpolation factors (0..<1) for the frames to emit after it.
    /// Example 24 -> 60: ratio 2.5, emits 1 or 2 factors per source frame.
    func factorsAfterSourceFrame(targetFPS: Double) -> [Double] {
        guard sourceFPS > 0, targetFPS > sourceFPS else { return [] }
        phase += targetFPS / sourceFPS
        var factors: [Double] = []
        while phase >= 1 {
            // factor of the frame emitted at this step within the current interval
            let whole = floor(phase)
            _ = whole
            phase -= 1
            // The emitted frame sits at (1 - phase) through the interval.
            factors.append(min(0.999, max(0.001, 1 - phase)))
        }
        return factors
    }

    /// Record a measured output-frame time; returns a degraded FPS if the
    /// budget has been exceeded for 30 consecutive frames, else nil.
    func noteFrameTime(_ ms: Double, targetFPS: Int) -> Int? {
        let budget = FrameRateMath.frameBudgetMs(targetFPS: Double(targetFPS))
        if ms > budget { overBudgetFrames += 1 } else { overBudgetFrames = 0 }
        return EngineRegistry.degradedFPS(from: targetFPS, measuredMs: ms, overBudgetFrames: overBudgetFrames)
    }

    func resetPhase() { phase = 0 }

    /// Pull any newly decoded frame from AVPlayerItemVideoOutput into the ring
    /// buffer. Called by DisplayLinkRenderer on every display-link tick.
    /// Without this call the ring buffer stays empty (the delegate has no
    /// "did output" callback in the public API — frames must be pulled).
    func pullLatestFrame() {
        guard let output = videoOutput, let item = player.currentItem else { return }
        let itemTime = item.currentTime()
        guard output.hasNewPixelBuffer(forItemTime: itemTime) else { return }
        var time = CMTime.zero
        if let buffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: &time) {
            ringBuffer.push(buffer, at: time)
            onNewFrame?()
        }
    }
}

// MARK: - AVPlayerItemVideoOutputDelegate
extension PlaybackEngine: AVPlayerItemVideoOutputDelegate {
    func outputSequenceWasFlushed(_ output: AVPlayerItemVideoOutput) {
        ringBuffer.clear()
    }

    func outputMediaDataWillChange(_ output: AVPlayerItemVideoOutput) {
        // A seek / flush is coming; the next frames will re-fill the buffer.
    }

    // Note: AVPlayerItemVideoOutputDelegate has no "didOutput" callback in the
    // public API; frames are pulled via hasNewPixelBuffer(forItemTime:) from the
    // display-link thread. See DisplayLinkRenderer.pullLatestFrame().
    // This delegate conformance exists for flush notifications only.
}
