#!/bin/bash
# StoryAudio — bộ gỡ cài đặt (chạy từ terminal)
#
# Dùng:  ./uninstall.sh [tùy-chọn]
#   --app        đưa StoryAudio.app vào Thùng rác (mặc định có nếu tìm thấy)
#   --all        xóa cả sách đã import, audio output, model TTS, venv .venv-engine,
#                file worker app copy vào thư mục làm việc
#   --data-only  chỉ xóa dữ liệu app (library/positions/bookmarks/settings)
#
# Không bao giờ đụng đến: file gốc của bạn trong thư mục làm việc (epub, audio đã
# xuất nằm ngoài output/, ref-*.wav, backup JSON, .venv-vieneu/.venv-tts, audiobook.py…)
set -euo pipefail

APP_SUPPORT="$HOME/Library/Application Support/StoryAudio"
# Workspace = thư mục chứa script này
WS="$(cd "$(dirname "$0")" && pwd)"
# Tìm app theo thứ tự cài đặt thực tế: /Applications (tự cài qua AppInstaller)
# → ~/Applications (máy hạn quyền) → build-app trong workspace (bản build thủ công)
APP="/Applications/StoryAudio.app"
[ -d "$APP" ] || APP="$HOME/Applications/StoryAudio.app"
[ -d "$APP" ] || APP="$WS/build-app/StoryAudio.app"

DATA_ONLY=0; DO_ALL=0; DO_APP=1
for arg in "$@"; do
  case "$arg" in
    --data-only) DATA_ONLY=1; DO_APP=0 ;;
    --all) DO_ALL=1 ;;
    --no-app) DO_APP=0 ;;
  esac
done

echo "==> StoryAudio Uninstaller"
if [ "$DATA_ONLY" = 1 ]; then
  rm -rf "$APP_SUPPORT"
  defaults delete com.storyaudio.app 2>/dev/null || true
  echo "    Đã xóa dữ liệu app (thư viện, vị trí nghe, bookmark, cài đặt)."
  echo "XONG."
  exit 0
fi

if [ "$DO_APP" = 1 ] && [ -d "$APP" ]; then
  osascript -e 'quit app "StoryAudio"' 2>/dev/null || true
  sleep 1
  DEST="$HOME/.Trash/StoryAudio.app"
  [ -e "$DEST" ] && DEST="$HOME/.Trash/StoryAudio-$(date +%s).app"
  mv "$APP" "$DEST" 2>/dev/null || echo "    (không chuyển được app vào Thùng rác — xóa tay: $APP)"
  echo "    Đã đưa StoryAudio.app vào Thùng rác."
fi

rm -rf "$APP_SUPPORT"
defaults delete com.storyaudio.app 2>/dev/null || true
echo "    Đã xóa dữ liệu app (~/Library/Application Support/StoryAudio + cài đặt)."

if [ "$DO_ALL" = 1 ]; then
  rm -rf "$WS/books" "$WS/output" "$WS/build" "$WS/models" "$WS/.venv-engine"
  rm -f "$WS/tts_worker.py" "$WS/catalog.json" "$WS/setup_runtime.sh"
  echo "    Đã xóa: books/ output/ build/ models/ .venv-engine + file worker trong thư mục làm việc."
  echo "    (model TTS tải lại được bất cứ lúc nào; file gốc của bạn không bị đụng đến)"
fi

echo "XONG."
