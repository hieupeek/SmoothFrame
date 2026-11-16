# SmoothFrame

[![Build and Release DMG](https://github.com/hieupeek/SmoothFrame/actions/workflows/build.yml/badge.svg)](https://github.com/hieupeek/SmoothFrame/actions/workflows/build.yml)

**Trình phát video macOS với nội suy khung hình thời gian thực — giống SmoothVideo Project (SVP), nhưng là app độc lập, mã nguồn mở, viết bằng Swift.**

> **English summary:** SmoothFrame is a standalone native macOS video player that interpolates video from 24/30 fps to 48–144 fps in real time (motion estimation / motion compensation, MEMC), inspired by SmoothVideo Project. Swift 6 + SwiftUI + Metal + AVFoundation, macOS 14+, Apple Silicon. Open source (MIT). Clean-room implementation — no SVP code.

> ⚠️ **Trạng thái thật:** Dự án được viết trên máy ảo Linux, **chưa biên dịch / chưa chạy trên máy Mac** (không có Xcode/Swift ở đây). Bạn cần mở `SmoothFrame.xcodeproj` bằng Xcode 16 trên MacBook Air và build. Các phần chưa kiểm chứng trên phần cứng thật được đánh dấu `TODO` / `UNTESTED` trong code.

## SmoothFrame là gì?

SVP không phải là trình phát — nó là một engine thương mại ($24.99, v4.7.2) móc vào mpv/VLC/IINA qua VapourSynth + MVTools để biến video 24 fps thành 60/120/144/240 fps. SmoothFrame làm điều tương tự, nhưng là **một app macOS độc lập**: mở file video, phát, nội suy ngay trong lúc phát — không cần mpv, không cần VapourSynth, không cần FFmpeg.

## So sánh với SVP

| Tính năng | SVP 4.7.2 | SmoothFrame (MVP) |
|---|---|---|
| Dạng sản phẩm | Engine/plugin cho mpv, VLC, IINA | App macOS độc lập (SwiftUI) |
| Giá / giấy phép | $24.99 lifetime, proprietary | Miễn phí, MIT |
| Nền tảng | Windows / Linux / macOS 13+ | macOS 14+, Apple Silicon |
| Nội suy thời gian thực | MVTools (VapourSynth), GPU | Metal block-matching + Blend + Optical Flow (hệ thống) |
| Nội suy bằng AI | RIFE (tùy chọn) | RIFE v4.25 qua CoreML — stub, cần tự thêm model |
| FPS đích | 60 / 120 / 144 / 240 | 48 / 50 / 60 / 72 / 90 / 120 / 144 / **180** |
| Upscale | Không (giữ nguyên độ phân giải) | Có — lên 1080p / **2K QHD 2560×1440** / 4K (Metal Lanczos/bilinear, không phải AI) |
| Xuất file offline | SVPcode | `OfflineExporter` (AVAssetWriter → MP4 60 fps) |
| Phát hiện cắt cảnh | Có | Có (histogram độ sáng) |
| Âm thanh | Không đổi | Không đổi (AVPlayer, chỉ nội suy hình) |
| Hỗ trợ Windows/Linux | Có | Không — chỉ macOS |

## Kiến trúc (tóm tắt)

```
File video ──► AVPlayer / AVPlayerItemVideoOutput ──► FrameRingBuffer (2 khung)
        (giải mã, âm thanh nguyên vẹn)                (thread-safe)
                                                        │
                              ┌─────────────────────────┼─────────────────────────┐
                              ▼                         ▼                         ▼
                        BlendEngine            MetalMotionEngine        AppleOpticalFlowEngine
                     (cross-fade, rẻ nhất)   (block matching 16×16   (VideoToolbox/AVFoundation,
                                              + warp, Metal compute)   macOS 14, Phase 2)
                              │                         │                         │
                              └──────────── SceneChangeDetector (cắt cảnh → không nội suy)
                                                        │
                                                        ▼
                              DisplayLinkRenderer (MTKView + Metal, CVDisplayLink)
                                                        │
                                                        ▼
                                              Màn hình 60–144 Hz
RIFE (CoreML, tùy chọn) ──► chỉ bật khi có model .mlmodelc trong
                            ~/Library/Application Support/SmoothFrame/Models
```

Chi tiết: xem [ARCHITECTURE.md](ARCHITECTURE.md) và [PLAN.md](PLAN.md).

## Màn 2K 180Hz — upscale + làm mượt lên 2560×1440 @ 180 fps

"2K" ở đây nghĩa là **QHD 2560×1440** (không phải 2048×1080 DCI 2K).

- **Preset một chạm "Màn 2K 180Hz"** trong sidebar: tự đặt 1440p + 180 fps + engine tự động. App tự phát hiện màn hình qua `DisplayDetector` (NSScreen/CGDisplay) và gợi ý preset khi thấy màn 2560×1440 @ 180 Hz.
- **Toán FPS:** 24→180 cần **6.5 khung trung gian/khung gốc (7.5×)**, 30→180 cần **5 khung**, 60→180 cần **2 khung**. Ngân sách mỗi khung đích chỉ **1000/180 ≈ 5.55 ms** — mức rất nặng.
- **Pipeline:** nội suy ở độ phân giải gốc trước (motion estimation ở nửa độ phân giải), **upscale lên 1440p sau** — tiết kiệm hiệu năng. Upscale dùng Metal Performance Shaders (`MPSImageLanczosScale` / `MPSImageBilinearScale`, quality thêm sharpen nhẹ), fallback Core Image `CILanczosScaleTransform`. Đây là upscale cổ điển, **không phải AI super-resolution** — không tự nhận là Real-ESRGAN.
- **Giới hạn phần cứng — nói thẳng:** MacBook Air (M1/M2/M3 base) **rất khó đạt real-time 1440p180 với engine nặng**. Ở 1440p180, `EngineRegistry` chỉ chọn Blend hoặc Metal Motion ở ME-scale thấp, **không chọn RIFE/Optical Flow Quality**; nếu thời gian/khung vượt ngân sách 30 khung liên tiếp, app **tự hạ 180 → 144 → 120 fps** và báo rõ trong stats overlay. Kỳ vọng thực tế trên Air: 1080p120 mượt, 1440p120 khả thi, 1440p180 chỉ với Blend hoặc trên chip M3 Pro/Max trở lên.
- **Export 1440p180 HEVC:** có trong `OfflineExporter`, kèm cảnh báo file rất lớn và xuất chậm (chậm hơn thời gian thực nhiều lần).

## Các engine nội suy

| Engine | Cách hoạt động | Khi nào dùng | Chi phí |
|---|---|---|---|
| `BlendEngine` | Trộn tuyến tính 2 khung (cross-fade) | Fallback, 4K, máy yếu | Rất rẻ, có ghosting nhẹ |
| `MetalMotionEngine` | Block matching 16×16, vector chuyển động 2 chiều, warp | Mặc định ở 1080p | Trung bình, cần GPU |
| `AppleOpticalFlowEngine` | Chuyển đổi frame-rate của hệ thống (VideoToolbox/AVFoundation) | Khi API hệ thống khả dụng | Thấp, phụ thuộc macOS |
| `RIFEEngine` | Mạng nơ-ron RIFE v4.25 qua CoreML | Tùy chọn, cần model do người dùng cung cấp | Cao, chất lượng tốt nhất |

`EngineRegistry` tự chọn engine theo độ phân giải + ngân sách khung hình (≤720p: Metal, 1080p: Metal, 4K: Blend/Optical Flow); người dùng có thể override thủ công.

## Build trên Mac

Yêu cầu: **macOS 14+, Xcode 16, Apple Silicon** (M1 trở lên).

```bash
git clone https://github.com/hieupeek/SmoothFrame.git
cd SmoothFrame
open SmoothFrame.xcodeproj
```

Trong Xcode: chọn scheme **SmoothFrame**, target **My Mac**, nhấn **⌘R**.

Không cần dependency ngoài: chỉ dùng framework hệ thống (AVFoundation, Metal, MetalKit, CoreML, VideoToolbox, CoreVideo). Không cần CocoaPods/SPM.

## CI/CD & .dmg

Không cần tự build trên máy: mỗi lần push lên `main` hoặc mở pull request, GitHub Actions (`.github/workflows/build.yml`, runner `macos-15` + Xcode 16) sẽ tự chạy test rồi build bản Release và đóng thành file `SmoothFrame.dmg`.

- **Tải .dmg:** vào tab **Actions** → chọn lần chạy mới nhất → mục **Artifacts** → `SmoothFrame-macOS` (giữ 30 ngày). Khi gắn tag `v1.0.0` trở lên, file `.dmg` sẽ đính kèm luôn vào **Releases**.
- **Chưa ký số / chưa notarize:** bản CI build là unsigned vì repo chưa có chứng chỉ Apple Developer. Trên máy của bạn, mở bằng chuột phải → **Open** (hoặc chạy `xattr -cr SmoothFrame.app`) thì dùng được. Muốn phân phối sạch qua Gatekeeper cho người khác thì cần tài khoản Apple Developer ($99/năm) + thêm secrets `APPLE_ID`, `APPLE_APP_PASSWORD`, `APPLE_TEAM_ID` và bước notarize vào workflow — đó là việc Phase 2, không phải lỗi build.

## Cách dùng

1. Mở app → **File → Open…** (⌘O) → chọn file video (MP4/MOV/MKV… mà AVFoundation đọc được).
2. Chọn **FPS đích**: 48 / 50 / 60 / 72 / 90 / 120 / 144.
3. Chọn **Engine**: Auto / Blend / Metal Motion / Optical Flow / RIFE.
4. Chọn **Profile**: Film (24→60, mượt vừa), Anime (giữ nét đường viền, threshold cắt cảnh cao), Sports (mượt tối đa).
5. Kéo **Smoothness** (hệ số nội suy) và **Scene threshold** (ngưỡng cắt cảnh).
6. Bật **Stats** (⌘I) để xem FPS nguồn/đích, thời gian/khung, số khung nội suy/bị rớt.
7. **Export…**: xuất bản 60 fps ra MP4 (tương đương SVPcode).

## Hạn chế (nói thẳng)

- **Chưa biên dịch/chạy trên Mac thật.** Code viết theo API công khai của Apple, nhưng chưa qua Xcode. Có thể có lỗi API nhỏ cần sửa khi build lần đầu.
- `AppleOpticalFlowEngine` là wrapper trung thực: macOS không có API VideoToolbox công khai nào tên "frame-rate conversion" mà tác giả chắc chắn 100% về chữ ký; file này gọi qua AVFoundation và ghi rõ API cần nối ở Phase 2, thay vì bịa tên hàm.
- `RIFEEngine` là stub: model RIFE (hzwer/RIFE, MIT) **không kèm theo** — người dùng tự tải/convert sang CoreML `.mlmodelc` và đặt vào `~/Library/Application Support/SmoothFrame/Models`.
- Metal block matching 16×16 là thuật toán cơ bản, chất lượng chưa bằng MVTools/RIFE; video chuyển động nhanh, cảnh phức tạp có thể có artifact.
- Chỉ Apple Silicon; không hỗ trợ Intel Mac, Windows, Linux.
- 1440p180 real-time trên MacBook Air base là mục tiêu "cố gắng", không phải cam kết — xem mục 2K 180Hz ở trên.
- MKV/AVI… chỉ phát được nếu AVFoundation/macOS đọc được codec (không có FFmpeg kèm theo).

## Roadmap

- **Phase 1 (MVP — repo này):** phát + nội suy Blend/Metal, cắt cảnh, stats, export MP4.
- **Phase 2:** nối API optical-flow hệ thống thật, RIFE CoreML chạy được, HDR/SDR tone mapping, profile Anime tinh chỉnh.
- **Phase 3:** 240 fps, VRR/ProMotion, xử lý 4K bằng Metal tile, xuất ProRes, CLI `smoothframe`.

## Giấy phép

MIT — xem [LICENSE](LICENSE). Đây là clean-room implementation, không chứa code của SVP (phần mềm proprietary).
