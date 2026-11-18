#!/bin/bash
# StoryAudio — cài runtime Python engine vào workspace (tải từ internet lần đầu).
# Dùng: setup_runtime.sh <workspace>
set -o pipefail
WS="${1:?thiếu tham số thư mục làm việc}"
cd "$WS" || exit 1

# Chọn python phù hợp (ưu tiên 3.12/3.11)
PY=""
for c in python3.12 python3.11 python3; do
  if command -v "$c" >/dev/null 2>&1; then PY="$c"; break; fi
done
[ -z "$PY" ] && { echo "Không tìm thấy python3 trên máy — cài Python từ python.org rồi chạy lại."; exit 1; }
echo "Dùng $($PY --version)..."

if [ ! -x "$WS/.venv-engine/bin/python" ]; then
  echo "Tạo venv .venv-engine..."
  "$PY" -m venv .venv-engine || exit 1
fi

"$WS/.venv-engine/bin/pip" install --upgrade pip 2>&1 | tail -1
echo "Cài vieneu + edge-tts + kokoro-onnx (tải từ PyPI, có thể mất vài phút)..."
# misaki-fork[en] (G2P tiếng Anh cho engine Kokoro) kéo theo spacy/torch —
# nặng thêm ~1.3GB đĩa nhưng không chiếm RAM khi không dùng Kokoro.
"$WS/.venv-engine/bin/pip" install vieneu edge-tts kokoro-onnx "misaki-fork[en]" || exit 1
# Prefetch spacy model cho misaki (13MB) — tránh tải lúc nạp engine Kokoro lần đầu
"$WS/.venv-engine/bin/python" -m spacy download en_core_web_sm 2>&1 | tail -1 || true
echo "XONG: runtime đã sẵn sàng tại .venv-engine"
