#!/bin/bash
# StoryAudio — đóng gói file .dmg phát hành (bổ sung cho make_app.sh)
#
# Dùng:  ./make_dmg.sh
#   → build-app/StoryAudio-<version>.dmg (layout chuẩn: app + shortcut Applications)
#
# Người dùng mở app từ trong DMG → app tự hỏi "Chuyển vào Applications?" rồi tự
# copy + khởi động lại (xem AppInstaller.swift) — không cần kéo thả thủ công.
#
# Cần StoryAudio.app đã build (script tự chạy make_app.sh nếu chưa có).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build-app/StoryAudio.app"

if [ ! -d "$APP" ]; then
  echo "==> Chưa có StoryAudio.app — chạy make_app.sh trước"
  "$ROOT/make_app.sh"
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="$ROOT/build-app/StoryAudio-$VERSION.dmg"
RW="$ROOT/build-app/StoryAudio-rw.dmg"
STAGING="$ROOT/build-app/dmg-staging"
# Mountpoint riêng thay vì /Volumes/StoryAudio — tránh đụng DMG phát hành cũ
# đang được mount sẵn trên máy (trường hợp đó Finder cũng không nhầm volume).
MNT="$ROOT/build-app/dmg-mount"

echo "==> Dựng staging (app + shortcut Applications)"
rm -rf "$STAGING" "$RW" "$MNT"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

echo "==> Tạo DMG ghi được (để Finder sắp icon)"
hdiutil create -volname "StoryAudio" -srcfolder "$STAGING" -format UDRW -ov "$RW" >/dev/null

echo "==> Mount + sắp icon qua Finder"
mkdir -p "$MNT"
# Không dùng -nobrowse: Finder không nhìn thấy volume bị ẩn → không script được
hdiutil attach "$RW" -readwrite -mountpoint "$MNT" >/dev/null
# Sắp icon + kích thước cửa sổ. Finder cần vài giây để nhận volume mới mount →
# thử lại tối đa 5 lần. Thất bại không làm hỏng DMG — chỉ mất vị trí icon đẹp.
POS_OK=0
for _ in 1 2 3 4 5; do
  if osascript <<EOF >/dev/null 2>&1
tell application "Finder"
    tell disk "StoryAudio"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {200, 120, 860, 500}
        set position of item "StoryAudio.app" of container window to {140, 160}
        set position of item "Applications" of container window to {480, 160}
        update
    end tell
end tell
EOF
  then POS_OK=1; break; fi
  sleep 2
done
if [ "$POS_OK" = 1 ]; then echo "    Đã sắp icon"; else echo "    (không sắp được icon qua Finder — DMG vẫn dùng được)"; fi
# Chờ Finder ghi .DS_Store xuống volume rồi mới ngắt mount
sync
sleep 2

echo "==> Ngắt mount + nén DMG"
hdiutil detach "$MNT" >/dev/null || hdiutil detach "$MNT" -force >/dev/null
hdiutil convert "$RW" -format UDZO -o "$DMG" -ov >/dev/null
rm -rf "$RW" "$STAGING" "$MNT"

echo "==> Xong: $DMG"
echo "    Kiểm tra: hdiutil attach '$DMG' -nobrowse"
