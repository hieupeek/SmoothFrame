import CoreML
import CoreVideo
import Foundation

/// RIFE (Real-Time Intermediate Flow Estimation) neural interpolation, v4.25.
///
/// Model source: hzwer/RIFE (MIT licence), https://github.com/hzwer/RIFE
/// The model is NOT bundled with this repo (size + licence hygiene + the user
/// must convert it to CoreML themselves). Expected location:
///   ~/Library/Application Support/SmoothFrame/Models/RIFE-v4.25.mlmodelc
///
/// Behaviour:
///   * Model present  -> loads via MLModel, interpolates on Neural Engine/GPU.
///   * Model missing  -> throws .modelMissing with the exact path + instructions.
///   * This is a STUB in the MVP: `loadModel()` and the prediction path are
///     written against the real CoreML API (MLModel, MLFeatureProvider), but
///     the RIFE-specific input/output feature names ("img0", "img1", "output")
///     must be confirmed against the converted model in Phase 2, and the
///     pixel-buffer <-> MLMultiArray conversion is marked TODO.
///   * RIFE is deliberately EXCLUDED from auto-select at 1440p180 (too heavy).
final class RIFEEngine: FrameInterpolationEngine {
    var name: String { "RIFE v4.25 (CoreML)" }
    var maxScale: Double { 7.5 }

    static let modelsDirectoryName = "RIFE-v4.25.mlmodelc"

    enum RIFEState {
        case notChecked
        case modelMissing(URL)
        case ready
        case failed(String)
    }

    private(set) var state: RIFEState = .notChecked
    private var model: MLModel?
    private let blendFallback = BlendEngine()

    static func modelsDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return appSupport.appendingPathComponent("SmoothFrame/Models", isDirectory: true)
    }

    static func expectedModelURL() -> URL {
        modelsDirectory().appendingPathComponent(modelsDirectoryName, isDirectory: true)
    }

    func estimatedCostMs(width: Int, height: Int) -> Double {
        // RIFE on Neural Engine: ~15-30 ms/frame at 1080p (estimate, UNTESTED).
        // Far above the 5.55 ms budget at 180 fps — hence excluded there.
        Double(width * height) / Double(1920 * 1080) * 20.0
    }

    func supportsResolution(width: Int, height: Int) -> Bool {
        // RIFE v4.25 reference works best at <= 1080p; 4K needs tiling (Phase 2).
        width <= 1920 && height <= 1080
    }

    /// Attempt to load the model. Safe to call repeatedly; caches the result.
    @discardableResult
    func loadModelIfNeeded() -> RIFEState {
        if case .ready = state { return state }
        let url = Self.expectedModelURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            state = .modelMissing(url)
            return state
        }
        do {
            let config = MLModelConfiguration()
            config.computeUnits = .all // Neural Engine + GPU + CPU
            model = try MLModel(contentsOf: url, configuration: config)
            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
        }
        return state
    }

    func interpolate(_ request: InterpolationRequest) throws -> CVPixelBuffer? {
        switch loadModelIfNeeded() {
        case .modelMissing(let url):
            throw InterpolationError.modelMissing(
                "RIFE model not found at \(url.path). Download RIFE v4.25 (hzwer/RIFE, MIT), " +
                "convert it to CoreML (.mlmodelc) and place it there. See docs/SVP-RESEARCH.md.")
        case .failed(let why):
            throw InterpolationError.failed("RIFE model failed to load: \(why)")
        case .ready:
            break
        case .notChecked:
            throw InterpolationError.unavailable("RIFE model state unknown")
        }
        // TODO(Phase 2): implement the real prediction. Steps:
        //   1. Convert request.previous / request.current to the model's input
        //      feature provider (confirm feature names in the converted model:
        //      likely "img0"/"img1" + timestep; DO NOT assume — inspect with
        //      `MLModel.modelDescription` at runtime first).
        //   2. model.prediction(from:) -> output feature -> CVPixelBuffer.
        //   3. Fall back to Blend on any prediction error.
        // Until then, deliberately NOT pretending: fall through to Blend would
        // mislabel blended frames as "RIFE". Throw instead.
        throw InterpolationError.unavailable(
            "RIFE prediction path is a stub in the MVP (Phase 2). Model loads, inference is not wired yet.")
    }
}
