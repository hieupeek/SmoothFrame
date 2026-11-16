import Foundation

/// Auto-selects an interpolation engine for a given resolution + frame budget,
/// MacLC-style: cheap engines for high resolutions / high frame rates.
/// Manual override (EngineChoice) always wins over auto-select.
enum EngineRegistry {

    /// Result of auto-selection, including any FPS degradation applied.
    struct Selection {
        var engine: EngineChoice
        var targetFPS: Int          // May be lower than requested if degraded.
        var reason: String
        var degraded: Bool { targetFPS != requestedFPS }
        var requestedFPS: Int
    }

    static func autoSelect(sourceFPS: Double, targetFPS: Int,
                           width: Int, height: Int,
                           rifeAvailable: Bool = false) -> Selection {
        let pixels = width * height
        let budgetMs = FrameRateMath.frameBudgetMs(targetFPS: Double(targetFPS))

        // 1440p180 is the hardest case: 5.55 ms/frame at 1440p.
        // Only Blend or Metal motion at low ME scale can plausibly fit.
        // RIFE and Optical Flow (quality) are NEVER auto-selected here.
        if height >= 1440 && targetFPS >= 180 {
            let metalCost = MetalMotionEngine().estimatedCostMs(width: width, height: height)
            if metalCost <= budgetMs {
                return Selection(engine: .metalMotion, targetFPS: targetFPS, reason: "1440p180: Metal Motion fits the 5.55 ms budget (estimate).", requestedFPS: targetFPS)
            }
            // Metal too slow on paper -> Blend at 180 if it fits, else degrade to 120.
            let blendCost = BlendEngine().estimatedCostMs(width: width, height: height)
            if blendCost <= budgetMs {
                return Selection(engine: .blend, targetFPS: targetFPS, reason: "1440p180: Metal too slow, using Blend (lowest cost).", requestedFPS: targetFPS)
            }
            return Selection(engine: .blend, targetFPS: 120,
                             reason: "1440p180 exceeds the 5.55 ms/frame budget on this hardware — auto-degraded to 120 fps (8.33 ms/frame).",
                             requestedFPS: targetFPS)
        }

        // 4K: Blend (or system optical flow when wired); never Metal/RIFE in real time.
        if height >= 2160 {
            return Selection(engine: .blend, targetFPS: targetFPS,
                             reason: "4K: Blend only in real time; Metal/RIFE too heavy.",
                             requestedFPS: targetFPS)
        }

        // 1080p and below: Metal Motion is the default.
        if pixels <= 1920 * 1080 {
            if targetFPS <= 120 {
                return Selection(engine: .metalMotion, targetFPS: targetFPS,
                                 reason: "1080p or lower, <=120 fps: Metal Motion.",
                                 requestedFPS: targetFPS)
            }
            // 144 fps at 1080p: Metal if it fits the 6.94 ms budget, else Blend.
            let metalCost = MetalMotionEngine().estimatedCostMs(width: width, height: height)
            if metalCost <= budgetMs {
                return Selection(engine: .metalMotion, targetFPS: targetFPS,
                                 reason: "1080p144: Metal Motion fits budget.", requestedFPS: targetFPS)
            }
            return Selection(engine: .blend, targetFPS: targetFPS,
                             reason: "1080p144: Metal over budget, using Blend.", requestedFPS: targetFPS)
        }

        // 1440p at <=144 fps: Metal if it fits, else Blend.
        let metalCost = MetalMotionEngine().estimatedCostMs(width: width, height: height)
        if metalCost <= budgetMs {
            return Selection(engine: .metalMotion, targetFPS: targetFPS,
                             reason: "1440p: Metal Motion fits budget.", requestedFPS: targetFPS)
        }
        return Selection(engine: .blend, targetFPS: targetFPS,
                         reason: "1440p: Metal over budget, using Blend.", requestedFPS: targetFPS)
    }

    /// Runtime guard: if measured frame time exceeds the budget for N frames,
    /// step the target FPS down (180 -> 144 -> 120 -> 90 -> 60) and report it.
    /// Pure logic, unit-tested.
    static func degradedFPS(from targetFPS: Int, measuredMs: Double, overBudgetFrames: Int) -> Int? {
        guard overBudgetFrames >= 30 else { return nil }
        let budget = FrameRateMath.frameBudgetMs(targetFPS: Double(targetFPS))
        guard measuredMs > budget else { return nil }
        let ladder = [180, 144, 120, 90, 72, 60, 50, 48]
        guard let idx = ladder.firstIndex(of: targetFPS), idx + 1 < ladder.count else { return nil }
        return ladder[idx + 1]
    }

    /// Build a concrete engine instance for a choice. Returns nil for RIFE
    /// when no model is present (caller shows the model-missing message).
    static func makeEngine(for choice: EngineChoice) -> (any FrameInterpolationEngine)? {
        switch choice {
        case .auto: return nil // Caller must call autoSelect first.
        case .blend: return BlendEngine()
        case .metalMotion: return MetalMotionEngine()
        case .opticalFlow:
            if #available(macOS 14, *) { return AppleOpticalFlowEngine() }
            return nil
        case .rife: return RIFEEngine()
        }
    }
}
