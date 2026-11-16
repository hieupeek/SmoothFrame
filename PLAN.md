# PLAN.md — Kế hoạch xây dựng SmoothFrame

## 1. Mục tiêu

Xây một trình phát video macOS độc lập, mã nguồn mở, nội suy khung hình thời gian thực kiểu SVP:

- Mở video 24/30 fps → phát mượt ở 48–144 fps trên màn hình Mac (ProMotion 120 Hz).
- Không phụ thuộc mpv / VapourSynth / FFmpeg / Python.
- Swift-first, dùng framework hệ thống của Apple.

Người dùng mục tiêu: người xem phim/anime/thể thao trên MacBook Air (Apple Silicon) muốn trải nghiệm mượt như SVP mà không phải trả phí hay cài đặt phức tạp.

## 2. Phạm vi

### MVP (Phase 1) — repo này

- [x] App SwiftUI, mở file, phát bằng AVPlayer.
- [x] Frame pump qua `AVPlayerItemVideoOutput` (CVPixelBuffer).
- [x] 3 engine: Blend (luôn chạy được), MetalMotion (block matching + warp), OpticalFlow wrapper (trung thực, Phase 2 nối API thật).
- [x] RIFE stub (CoreML, chờ model người dùng cung cấp).
- [x] Phát hiện cắt cảnh (histogram luma).
- [x] Auto-select engine theo độ phân giải.
- [x] FPS đích 48–144, profile Film/Anime/Sports, stats overlay.
- [x] Export offline MP4 60 fps (SVPcode tương đương).
- [x] Upscale 2K 180Hz: module `Upscaling/` (Metal MPS Lanczos/bilinear + sharpen, fallback Core Image), `DisplayDetector` (phát hiện màn 2560×1440 @ 180 Hz), preset một chạm "Màn 2K 180Hz", target FPS 180, auto-degrade 180→120 khi vượt ngân sách 5.55 ms/khung, export 1440p180 HEVC kèm cảnh báo.
- [x] Unit test logic thuần (FPS math, scene threshold, auto-select).

### Phase 1.5 — 2K 180Hz (đã làm trong repo này)

- Nội suy ở độ phân giải gốc → upscale sau (xem ARCHITECTURE.md §9).
- Preset màn 2K 180Hz, DisplayDetector, auto-degrade FPS.
- Rủi ro lớn nhất: MacBook Air không đủ 5.55 ms/khung ở 1440p180 → giảm nhẹ: chỉ Blend/Metal-ME-thấp, tự hạ FPS, báo rõ cho người dùng thay vì giật hình.

### Phase 2

- Nối API frame-rate conversion hệ thống thật (kiểm chứng chữ ký API trên Xcode 16 / macOS 14 SDK).
- RIFE v4.25 CoreML chạy được end-to-end (convert model, benchmark trên M1/M2/M3).
- Tinh chỉnh Metal engine: search radius thích ứng, sub-pixel, deblock.
- HDR (HLG/PQ) giữ nguyên metadata khi nội suy; SDR tone mapping.
- Lưu profile người dùng, nhớ FPS/engine theo từng file.

### Phase 3

- 240 fps, ProMotion/VRR sync, 4K tile-based Metal.
- Xuất ProRes / HEVC 10-bit.
- CLI `smoothframe` (batch convert).
- Benchmark suite + so sánh chất lượng với SVP (PSNR/SSIM trên clip mẫu).

### Ngoài phạm vi (không làm)

- Windows/Linux, Intel Mac.
- Phát trực tuyến (streaming), DRM (Widevine/FairPlay playback).
- Tự tải model RIFE có bản quyền / model Cambridge.

## 3. Kiến trúc

Xem [ARCHITECTURE.md](ARCHITECTURE.md). Tóm tắt: AVFoundation decode → ring buffer 2 khung → engine nội suy (protocol chung) → MTKView render theo CVDisplayLink → stats. Âm thanh đi thẳng AVPlayer, không chạm vào.

## 4. So sánh engine

| Tiêu chí | Blend | MetalMotion | OpticalFlow (hệ thống) | RIFE CoreML |
|---|---|---|---|---|
| Chất lượng | Thấp (ghosting) | Trung bình | Trung bình–cao | Cao |
| Chi phí GPU | Rất thấp | Trung bình | Thấp | Cao |
| Độ trễ | ~0 | 1 khung | 1 khung | 1–2 khung |
| Phụ thuộc | Không | Metal | macOS 14 API | Model .mlmodelc |
| Trạng thái | Xong | Xong (chưa test trên Mac) | Wrapper, Phase 2 | Stub |

## 5. Rủi ro

| Rủi ro | Mức | Giảm thiểu |
|---|---|---|
| API VideoToolbox frame-rate conversion không tồn tại / khác chữ ký | Cao | Không bịa tên hàm; wrapper + TODO rõ ràng, fallback Blend/Metal |
| Metal block matching chậm ở 4K trên M1 base | Trung bình | Auto-select Blend ở 4K; tile + giảm search radius |
| AVPlayerItemVideoOutput + CVDisplayLink lệch nhịp, giật | Trung bình | Timebase sync, đo frameTimeMs, stats droppedFrames |
| RIFE CoreML model convert lỗi / chậm | Trung bình | Stub tách biệt, không chặn MVP |
| Chưa có máy Mac để build/test | Cao | Ghi rõ trong README; code theo API công khai, guard availability |
| 1440p180 vượt ngân sách 5.55 ms/khung trên MacBook Air | Cao | Chỉ Blend/Metal-ME-thấp ở 1440p180; auto-degrade 180→120; upscale sau nội suy; báo rõ trong stats |
| Artifact ở cảnh chuyển động nhanh / anime | Trung bình | Scene detector + profile Anime (threshold cao, smoothness thấp) |

## 6. Timeline ước tính (1 người, bán thời gian)

| Giai đoạn | Việc | Ước tính |
|---|---|---|
| Tuần 1 | Khung app + AVPlayer + MTKView render pass-through | 1 tuần |
| Tuần 2 | Blend + MetalMotion + scene detector + stats | 1 tuần |
| Tuần 3 | Export offline + profiles + auto-select + test | 1 tuần |
| Tuần 4 | Build trên Mac thật, sửa lỗi API, benchmark M1 | 1 tuần |
| Phase 2 | OpticalFlow thật + RIFE CoreML + HDR | 3–4 tuần |
| Phase 3 | 240 fps, 4K tile, ProRes, CLI | 4+ tuần |

## 7. Definition of Done (MVP)

- [ ] Mở được MP4 1080p 24 fps trên MacBook Air M1, phát ở 60 fps không giật > 2% khung rớt.
- [ ] Chuyển engine Blend ↔ Metal không crash; cắt cảnh không tạo khung "ma".
- [ ] Stats hiển thị đúng source FPS / output FPS / frameTimeMs.
- [ ] Export 1 clip 30 giây ra MP4 60 fps, mở lại phát được.
- [ ] `SmoothFrameTests` pass toàn bộ trên Xcode (gồm test 24/30/60→180, scale 1080p→1440p = 1.333×, 720p→1440p = 2×, budget 5.55 ms).
- [ ] Preset "Màn 2K 180Hz" áp dụng đúng 1440p + 180 fps; khi vượt ngân sách, app tự hạ fps và hiển thị lý do.
- [ ] Không còn `TODO` chặn build; các `TODO` còn lại đều ghi rõ Phase 2.
