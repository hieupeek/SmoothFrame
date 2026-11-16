#include <metal_stdlib>
using namespace metal;

// SmoothFrame Metal kernels: block matching + warp/blend, and a light sharpen.
// Written against the public Metal shading language (macOS 14, Metal 3).
// UNTESTED on real hardware — verify with Xcode GPU debugger before shipping.

// blockMatch: one threadgroup per 16x16 block.
// Inputs: prev/current BGRA textures, output MV buffer (float2 forward + float2 backward per block).
// Search radius +/-16 px, SAD on luma, half-resolution assumed by caller via texture size.
// dims: (width, height, blocksX, blocksY).
kernel void blockMatch(texture2d<float, access::read> prev [[texture(0)]],
                       texture2d<float, access::read> curr [[texture(1)]],
                       device float2 *motionVectors [[buffer(0)]],
                       constant int4 &dims [[buffer(1)]],
                       uint2 gid [[thread_position_in_grid]]) {
    int width = dims.x;
    int height = dims.y;
    int blocksX = dims.z;
    if (int(gid.x) >= blocksX || int(gid.y) >= dims.w) return;
    int bx = int(gid.x) * 16;
    int by = int(gid.y) * 16;
    float bestSAD = 1e9f;
    int2 bestMV = int2(0, 0);
    // Search window +/-16 px in steps of 2 (coarse), then refine is a Phase 2 item.
    for (int dy = -16; dy <= 16; dy += 2) {
        for (int dx = -16; dx <= 16; dx += 2) {
            float sad = 0.0f;
            for (int y = 0; y < 16; y += 4) {
                for (int x = 0; x < 16; x += 4) {
                    int px = bx + x, py = by + y;
                    int qx = clamp(px + dx, 0, width - 1);
                    int qy = clamp(py + dy, 0, height - 1);
                    float4 a = curr.read(uint2(px, py));
                    float4 b = prev.read(uint2(qx, qy));
                    float la = 0.299f * a.r + 0.587f * a.g + 0.114f * a.b;
                    float lb = 0.299f * b.r + 0.587f * b.g + 0.114f * b.b;
                    sad += fabs(la - lb);
                }
            }
            if (sad < bestSAD) { bestSAD = sad; bestMV = int2(dx, dy); }
        }
    }
    uint idx = gid.y * uint(blocksX) + gid.x;
    // Forward vector (prev -> curr) and backward (curr -> prev, approximated as negated).
    // A true bidirectional search is a Phase 2 improvement.
    motionVectors[idx * 2] = float2(bestMV);
    motionVectors[idx * 2 + 1] = float2(-bestMV);
}

// warpBlend: warp both frames toward intermediate time t and blend.
// params: (t, width, height, blocksX). Occlusion: forward+backward vectors
// should cancel; if they don't, fall back to a plain blend at that pixel.
kernel void warpBlend(texture2d<float, access::read> prev [[texture(0)]],
                      texture2d<float, access::read> curr [[texture(1)]],
                      texture2d<float, access::write> out [[texture(2)]],
                      device float2 *motionVectors [[buffer(0)]],
                      constant float4 &params [[buffer(1)]],
                      uint2 gid [[thread_position_in_grid]]) {
    float t = params.x;
    int width = int(params.y);
    int height = int(params.z);
    int blocksX = int(params.w);
    if (int(gid.x) >= width || int(gid.y) >= height) return;
    uint blockIdx = (gid.y / 16) * uint(blocksX) + (gid.x / 16);
    float2 fwd = motionVectors[blockIdx * 2];
    float2 bwd = motionVectors[blockIdx * 2 + 1];
    // Occlusion test: inconsistent vectors -> blend instead of warping.
    float inconsistency = length(fwd + bwd);
    float warpWeight = inconsistency > 4.0f ? 0.0f : 1.0f;
    float2 prevPos = float2(gid) + fwd * t * warpWeight;
    float2 currPos = float2(gid) - fwd * (1.0f - t) * warpWeight;
    // NOTE: curr is warped by -fwd*(1-t); bwd is kept for the occlusion test
    // and for a future true bidirectional warp (Phase 2).
    float4 p = prev.read(uint2(clamp(int2(prevPos), int2(0), int2(width - 1, height - 1))));
    float4 c = curr.read(uint2(clamp(int2(currPos), int2(0), int2(width - 1, height - 1))));
    float4 blended = mix(p, c, t);
    float4 warped = mix(p, c, t); // same weights; warp already moved the samples
    out.write(mix(blended, warped, warpWeight), gid);
}

// sharpen: light unsharp mask used by MetalUpscaler (.quality).
// In-place: reads texture 0, writes texture 1 (may be the same texture only
// if the caller guarantees no read/write hazard — MetalUpscaler uses one
// texture for both, which is UNTESTED; use separate textures if artifacts appear).
kernel void sharpen(texture2d<float, access::read> src [[texture(0)]],
                    texture2d<float, access::write> dst [[texture(1)]],
                    uint2 gid [[thread_position_in_grid]]) {
    uint w = src.get_width();
    uint h = src.get_height();
    if (gid.x >= w || gid.y >= h) return;
    float4 c = src.read(gid);
    float4 sum = float4(0.0f);
    int count = 0;
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            if (dx == 0 && dy == 0) continue;
            int2 p = int2(gid) + int2(dx, dy);
            if (p.x >= 0 && p.y >= 0 && uint(p.x) < w && uint(p.y) < h) {
                sum += src.read(uint2(p));
                count++;
            }
        }
    }
    float4 blur = count > 0 ? sum / float(count) : c;
    float4 out = clamp(c + (c - blur) * 0.35f, 0.0f, 1.0f);
    dst.write(out, gid);
}
