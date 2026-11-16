# SVP-RESEARCH.md — Nghiên cứu SmoothVideo Project (SVP)

Nguồn: svp-team.com (trang chủ SVP), wiki SVP, GitHub hzwer/RIFE, tài liệu
Apple (AVFoundation / Metal / CoreML / VideoToolbox). Tóm tắt từ nghiên cứu
trước của dự án; không sao chép code hay tài liệu của SVP (phần mềm proprietary).

## 1. SVP là gì?

- **SmoothVideo Project (SVP) không phải là trình phát video.** Nó là một
  engine thương mại ($24.99 lifetime, bản mới nhất v4.7.2) móc vào các trình
  phát có sẵn — mpv, VLC, IINA, MPC-HC — qua VapourSynth + MVTools.
- Chức năng chính: **motion estimation / motion compensation (MEMC)** —
  ước tính chuyển động giữa các khung hình và tạo khung trung gian, biến
  video 24/30 fps thành 60/120/144/240 fps trong thời gian thực, chạy trên GPU.
- Tính năng phụ: RIFE (nội suy bằng mạng nơ-ron) tùy chọn; SVPcode — xuất
  file video đã nội suy ra MP4 (offline); profile theo thể loại (phim/anime/
  thể thao); phát hiện cắt cảnh; hỗ trợ Windows / Linux / macOS 13+.

## 2. Cách SVP hoạt động (mức khái niệm)

1. Trình phát (mpv) giải mã video, đưa khung hình cho SVP qua VapourSynth.
2. MVTools ước tính vector chuyển động theo block, tạo khung trung gian bằng
   motion compensation, xử lý occlusion (vật bị che khuất) và cắt cảnh.
3. Khung đã nội suy trả lại trình phát để hiển thị đúng nhịp màn hình.
4. Âm thanh không bị chạm vào; đồng bộ dựa trên clock phát lại.

## 3. Cái gì SmoothFrame clone, cái gì làm khác

| Khía cạnh | SVP | SmoothFrame (làm khác có chủ đích) |
|---|---|---|
| Dạng sản phẩm | Engine/plugin cho mpv/VLC/IINA | App macOS độc lập, mở file là phát |
| Giá | $24.99, proprietary | Miễn phí, MIT, clean-room |
| Stack | VapourSynth + MVTools (C++/Python) | Swift 6 + AVFoundation + Metal, không Python/FFmpeg |
| MEMC | MVTools | Metal block matching 16×16 tự viết |
| AI | RIFE (kèm sẵn) | RIFE CoreML stub — model do người dùng tự cung cấp |
| Nền tảng | Win/Linux/macOS | Chỉ macOS 14+, Apple Silicon |
| Upscale 2K 180Hz | Không phải tính năng chính | Có: MPS Lanczos + preset màn 2560×1440 @ 180 Hz |

## 4. RIFE — nguồn model

- RIFE (Real-Time Intermediate Flow Estimation), hzwer/RIFE, giấy phép MIT.
- SmoothFrame KHÔNG kèm model. Người dùng tự tải RIFE v4.25, convert sang
  CoreML `.mlmodelc` (coremltools) và đặt vào
  `~/Library/Application Support/SmoothFrame/Models/RIFE-v4.25.mlmodelc`.
- Tương tự, Real-ESRGAN (upscale AI) chỉ được nhắc như hướng Phase 3,
  không có code giả trong repo.

## 5. Giới hạn đã biết của hướng tiếp cận macOS-native

- Không có API VideoToolbox công khai nào được xác minh là "frame-rate
  conversion session" — `AppleOpticalFlowEngine` là wrapper trung thực, chờ
  nối API thật ở Phase 2 (xem ghi chú trong file).
- AVPlayer + `AVPlayerItemVideoOutput` là cách chính thống để lấy khung hình
  đã giải mã trên macOS; đồng bộ A/V dựa vào timebase của AVPlayer.
- Metal Performance Shaders (`MPSImageLanczosScale`) là cách chính thống để
  upscale real-time; không phải AI super-resolution.
