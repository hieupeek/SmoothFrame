# Tải bản build (.dmg) từ CI

Mỗi lần push lên `main`, GitHub Actions tự build app và đóng `.dmg`
(xem `.github/workflows/build.yml`).

1. Mở tab **Actions** của repo `hieupeek/SmoothFrame`.
2. Chọn lần chạy (workflow run) mới nhất của **Build and Release DMG**.
3. Kéo xuống mục **Artifacts** → tải `SmoothFrame-macOS` (file `SmoothFrame.dmg`,
   giữ 30 ngày).
4. Mở file `.dmg`, kéo `SmoothFrame.app` vào `Applications`.

Lưu ý:

- Bản CI là **unsigned** (chưa ký số / chưa notarize). Lần đầu mở, chuột phải
  vào app → **Open** (hoặc chạy `xattr -cr /Applications/SmoothFrame.app`).
- Khi có tag `vX.Y.Z`, file `.dmg` sẽ đính kèm vào **Releases** thay vì chỉ
  nằm trong Artifacts.
