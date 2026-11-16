# ARCHITECTURE.md — Kiến trúc SmoothFrame

## 1. Pipeline tổng thể

```
┌──────────────┐   AVPlayerItemVideoOutput    ┌──────────────────┐
│  AVPlayer    │ ── CVPixelBuffer (nguồn) ──► │ FrameRingBuffer  │
│  (decode +   │    24/30 fps, audio riêng    │  (2 khung,       │
│   audio)     │                              │   thread-safe)   │
└──────────────┘                              └───────┬──────────┘
                                                      │ prev + current
                                                      ▼
                              ┌───────────────────────────────────────┐
                              │        FrameInterpolationEngine       │
                              │  Blend │ MetalMotion │ OpticalFlow    │
                              │  RIFE (stub)                          │
                              │  + SceneChangeDetector (cắt cảnh)     │
                              └───────────────────┬───────────────────┘
                                                  │ khung nội suy (factor 0..<1)
                                                  ▼
                              ┌───────────────────────────────────────┐
                              │  DisplayLinkRenderer (MTKView)      │
                              │  CVDisplayLink @ 60–144 Hz            │
                              │  Metal texture từ CVPixelBuffer       │
                              └───────────────────┬───────────────────┘
                                                  ▼
                                              Màn hình
```

Âm thanh: AVPlayer phát trực tiếp, không qua pipeline nội suy. Đồng bộ A/V dựa vào
`itemTime(forHostTime:)` / timebase của AVPlayer — hình chỉ "đuổi theo" clock của audio.

## 2. Modules

| Module | File | Trách nhiệm |
|---|---|---|
| App/UI | `SmoothFrameApp.swift`, `ContentView.swift` | SwiftUI, menu, sidebar, stats |
| Playback | `Player/PlaybackEngine.swift` | AVPlayer, frame pump, CVDisplayLink, timebase sync |
| Playback | `Player/FrameRingBuffer.swift` | Ring buffer 2 khung, lock NSLock |
| Playback | `Player/DisplayLinkRenderer.swift` | MTKView + Metal render, aspect-fit |
| Interpolation | `Interpolation/FrameInterpolationEngine.swift` | Protocol chung + request/error |
| Interpolation | `Interpolation/BlendEngine.swift` | Cross-fade (vImage/CPU lerp) |
| Interpolation | `Interpolation/MetalMotionEngine.swift` + `Motion.metal` | Block matching + warp (Metal compute) |
| Interpolation | `Interpolation/AppleOpticalFlowEngine.swift` | Wrapper frame-rate conversion hệ thống |
| Interpolation | `Interpolation/RIFEEngine.swift` | CoreML RIFE stub |
| Interpolation | `Interpolation/SceneChangeDetector.swift` | Histogram luma, ngưỡng cắt cảnh |
| Interpolation | `Interpolation/EngineRegistry.swift` | Auto-select theo độ phân giải/ngân sách |
| Export | `Export/OfflineExporter.swift` | AVAssetReader → interpolate → AVAssetWriter |
| Models | `Models/*.swift` | Settings, stats, video info |

## 3. Threading

- **Main actor / SwiftUI:** UI, settings, stats hiển thị.
- **AVPlayer callback queue:** `AVPlayerItemVideoOutput` delegate — copy pixel buffer vào ring buffer, không làm việc nặng ở đây.
- **Render thread (CVDisplayLink):** lấy prev/current, gọi engine, render. Engine Metal chạy async trên Metal command queue; Blend chạy CPU nhưng nhanh (< 2 ms ở 1080p).
- **Export queue:** `DispatchQueue` riêng, cancellable.
- Đồng bộ duy nhất giữa các thread là `FrameRingBuffer` (NSLock) — không share `CVPixelBuffer` đang bị mutate.

## 4. Frame timing math

Nguồn `fs` fps, đích `ft` fps. Số khung nội suy cần chèn giữa 2 khung nguồn liên tiếp:

```
n = ft / fs - 1          (ví dụ 24 → 60: 60/24 - 1 = 1.5 khung/khoảng)
```

Vì `n` thường không nguyên (1.5), dùng bộ tích lũy phase:

```
phase += ft / fs            // mỗi khung nguồn, phase tăng 2.5 (24→60)
while phase >= 1 { emit frame; phase -= 1 }
```

- Khung nguồn (phase integer) phát nguyên bản; khung nội suy có `factor = frac(phase)` trong (0, 1).
- Ví dụ 24→60: pattern lặp theo chu kỳ 5 khung nguồn → 12 khung đích: `S I I S I S I I S I S I` (S = nguồn, I = nội suy, factor 0.4/0.8 xen kẽ).
- 24→120: `n = 4` khung nội suy/khoảng, factor 0.2/0.4/0.6/0.8.
- 30→60: `n = 1`, factor 0.5 — trường hợp đẹp nhất.

Đồng bộ với màn hình: `CVDisplayLink` chạy đúng tần số màn hình (60/120/144 Hz);
nếu `ft` không chia hết cho tần số màn hình, khung đích gần nhất được giữ (held frame)
và đếm vào `droppedFrames`/`repeatedFrames` trong stats.

Ngân sách thời gian mỗi khung đích:

```
budget = 1000 / ft  ms     // 60 fps → 16.7 ms; 120 fps → 8.3 ms; 144 fps → 6.9 ms
```

Engine nào có `estimatedCostMs(resolution)` vượt budget sẽ bị `EngineRegistry` loại.

## 5. Scene-change detection

- Histogram luma 64-bin của mỗi khung nguồn (tính trên bản downscale 160×90).
- `diff = Σ |hist[i] - prevHist[i]| / 2` (0…1). Nếu `diff > sceneThreshold` (mặc định 0.35) → cắt cảnh.
- Khi cắt cảnh: không nội suy qua biên cắt — phát khung nguồn, reset phase tích lũy.
- Profile Anime đặt threshold cao hơn (0.45) vì anime có thay đổi nền đột ngột nhưng vẫn cùng cảnh.

## 6. Metal motion compensation (tóm tắt thuật toán)

1. Downscale 2 khung về luma ½ độ phân giải.
2. `blockMatch` kernel: mỗi block 16×16 ở khung `current` tìm block khớp nhất trong
   khung `prev` trong cửa sổ tìm kiếm (±16 px), theo SAD (sum of absolute differences).
3. Vector chuyển động 2 chiều: forward (prev→current) và backward (current→prev);
   kiểm tra nhất quán (occlusion test): vector forward + backward phải triệt tiêu gần nhau,
   nếu không đánh dấu occluded → fallback blend tại pixel đó.
4. `warpBlend` kernel: với factor `t`, warp cả 2 khung về thời điểm giữa
   (`prev` dịch `+t·v`, `current` dịch `-(1-t)·v`) rồi trộn theo trọng số occlusion.
5. Fallback: nếu device Metal không khả dụng → `BlendEngine`.

## 7. Đồng bộ audio/video

- Audio clock là master (`AVPlayer.rate`, `currentTime`).
- Mỗi lần CVDisplayLink tick: `hostTime → itemTime` để biết thời điểm video cần hiển thị;
  chọn cặp khung nguồn bao quanh thời điểm đó, tính `factor`, nội suy.
- Nếu decode chậm (khung nguồn chưa tới): giữ khung cũ, tăng `droppedFrames`, không tua audio.

## 8. Upscale + 2K 180Hz

### 8.1 Định nghĩa
"2K" = **QHD 2560×1440**. Target FPS 180. Toán nội suy:

| Nguồn → đích | Hệ số | Khung trung gian / khung gốc |
|---|---|---|
| 24 → 180 | 7.5× | **6.5** |
| 30 → 180 | 6× | **5** |
| 60 → 180 | 3× | **2** |

Ngân sách mỗi khung đích: **1000/180 ≈ 5.55 ms** (so với 16.7 ms ở 60 fps, 8.33 ms ở 120 fps).
Trong 5.55 ms đó phải xong cả nội suy + upscale + render — mức rất nặng.

### 8.2 Thứ tự pipeline: nội suy TRƯỚC, upscale SAU
```
Nguồn 1080p ──► nội suy ở 1080p (ME ở 540p, upsample vector) ──► upscale MPS Lanczos ──► 1440p @ 180 Hz
```
Lý do tiết kiệm hiệu năng:
- Nội suy (đặc biệt block matching) có chi phí ~tuyến tính theo số pixel.
  Nội suy ở 1080p thay vì 1440p giảm ~44% pixel phải xử lý
  (1920×1080 = 2.07 MP vs 2560×1440 = 3.69 MP, tỉ lệ 1.78×).
- Motion estimation chạy ở nửa độ phân giải (960×540) rồi upsample vector —
  vector chuyển động mượt theo không gian nên upsample ít mất chất lượng.
- Upscale (Lanczos/bilinear) rẻ hơn nhiều so với nội suy: ~1-2 ms ở 1440p
  trên GPU Apple Silicon, trong khi MEMC ở 1440p tốn ~7 ms (ước tính, UNTESTED).
- Upscale một lần trên khung đã nội suy, thay vì nội suy trên khung đã upscale.

### 8.3 Auto-select và auto-degrade ở 1440p180
`EngineRegistry.autoSelect`: ở 1440p180 chỉ xét Blend hoặc Metal Motion
(ME-scale thấp); **không bao giờ chọn RIFE/Optical Flow Quality** (quá nặng).
Nếu thời gian/khung đo được vượt ngân sách 30 khung liên tiếp,
`degradedFPS` hạ theo thang 180 → 144 → 120 → 90 → 60 và ghi lý do vào stats.
Người dùng thấy rõ "đã hạ fps vì quá tải" thay vì xem hình giật mà không biết.

### 8.4 Giới hạn phần cứng (nói thẳng)
- MacBook Air M1/M2/M3 base: kỳ vọng thực tế là 1080p120 mượt, 1440p120 khả thi,
  1440p180 chỉ với Blend (chất lượng thấp) hoặc không giữ được real-time.
- 1440p180 chất lượng cao (Metal MEMC đầy đủ / RIFE) cần M3 Pro/Max trở lên,
  hoặc chấp nhận export offline thay vì xem trực tiếp.
- Upscale Lanczos không tạo thêm chi tiết thật — chỉ làm 1080p đầy màn 1440p
  một cách sạch sẽ. AI super-resolution (Real-ESRGAN/CoreML) là Phase 3,
  export-only, không real-time.

## 9. RIFE (Phase 2)

Model RIFE v4.25 (hzwer/RIFE, MIT) convert sang CoreML `.mlmodelc`, đặt tại
`~/Library/Application Support/SmoothFrame/Models/`. `RIFEEngine` load bằng `MLModel`,
chạy trên Neural Engine/GPU. Khi không có model → `.modelMissing`, UI báo rõ.
