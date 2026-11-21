#!/bin/bash
# StoryAudio — cài runtime Python engine vào workspace (tải từ internet lần đầu).
# Dùng: setup_runtime.sh <workspace>
#
# Override cho dev/test (người dùng thường không cần đụng):
#   SA_PACKAGES="vieneu"     — cài danh sách package khác
#   SA_FORCE_MANAGED_PY=1    — bỏ qua Python trên máy, bắt buộc tải Python chuẩn
set -o pipefail
WS="${1:?thiếu tham số thư mục làm việc}"
cd "$WS" || exit 1

# App chạy GUI (mở từ Finder/Dock) chỉ nhận PATH tối thiểu (/usr/bin:/bin:…) —
# thêm sẵn các chỗ Homebrew/MacPorts hay cài Python để tìm được bản đủ mới
export PATH="/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:$HOME/.local/bin:$PATH"

# vieneu yêu cầu Python >= 3.10; Mac mới chỉ có python3 3.9 hệ thống của Apple
py_ge_310() {
  "$1" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' 2>/dev/null
}

find_good_python() {
  # Bản cài riêng của người dùng (Homebrew thường) — python3.9 hệ thống
  # không đạt nên không có trong danh sách này
  local c
  for c in python3.12 python3.11 python3.10 python3.13; do
    if command -v "$c" >/dev/null 2>&1 && py_ge_310 "$c"; then { echo "$c"; return 0; } fi
  done
  # /usr/bin/python3 chỉ có thật khi đã cài Command Line Tools; chạy shim khi
  # chưa có CLT sẽ bật hộp thoại cài CLT làm rối người dùng — bỏ qua
  if xcode-select -p >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 \
     && py_ge_310 python3; then { echo "python3"; return 0; } fi
  # Dò đường dẫn tuyệt đối: PATH của app GUI không chứa Homebrew nên
  # python3.12 có trên máy vẫn phải dò trực tiếp mới thấy
  for c in /opt/homebrew/bin/python3.12 /opt/homebrew/bin/python3.11 \
           /opt/homebrew/bin/python3.10 /opt/homebrew/bin/python3.13 \
           /usr/local/bin/python3.12 /usr/local/bin/python3.11 \
           /usr/local/bin/python3.10 /usr/local/bin/python3.13 \
           /opt/local/bin/python3.12 /opt/local/bin/python3.11 \
           /opt/local/bin/python3.10 /opt/local/bin/python3.13 \
           /opt/homebrew/opt/python@3.12/bin/python3.12 \
           /opt/homebrew/opt/python@3.11/bin/python3.11; do
    if [ -x "$c" ] && py_ge_310 "$c"; then { echo "$c"; return 0; } fi
  done
  return 1
}

# Tải CPython 3.12 bản dựng chính thức (python-build-standalone của Astral)
# về workspace — dùng khi máy chưa có Python >= 3.10 nào. In thông báo ra
# stderr, đường dẫn python ra stdout.
install_managed_python() {
  local tag="20261110" pyver="3.12.16" a asset base want p
  case "$(uname -m)" in
    arm64)  a="aarch64" ;;
    x86_64) a="x86_64" ;;
    *) echo "Không hỗ trợ kiến trúc máy: $(uname -m)" >&2; return 1 ;;
  esac
  asset="cpython-${pyver}+${tag}-${a}-apple-darwin-install_only.tar.gz"
  base="https://github.com/astral-sh/python-build-standalone/releases/download/${tag}"
  mkdir -p "$WS/.python" || return 1
  echo "Máy chưa có Python >= 3.10 — tải Python chuẩn từ GitHub (~25MB)…" >&2
  if ! curl -sSL --fail --retry 3 --retry-delay 2 --connect-timeout 20 \
       -o ".python/$asset" "$base/$asset"; then
    echo "Không tải được Python từ GitHub. Có thể cài tay Python 3.10+ (python.org" >&2
    echo "hoặc 'brew install python@3.12' nếu có Homebrew) rồi bấm cài lại." >&2
    return 1
  fi
  # Kiểm tra checksum trước khi chạy — lệch là xoá và dừng
  if curl -sSL --fail --retry 3 "$base/SHA256SUMS" -o ".python/SHA256SUMS"; then
    want="$(awk -v a="$asset" '$2 == a {print $1}' ".python/SHA256SUMS")"
    if [ -z "$want" ] \
       || ! (cd .python && echo "$want  $asset" | shasum -a 256 -c - >/dev/null); then
      echo "Checksum Python tải về không khớp — xoá file, vui lòng thử lại." >&2
      rm -f ".python/$asset" ".python/SHA256SUMS"
      return 1
    fi
  fi
  tar -xzf ".python/$asset" -C .python || {
    echo "Giải nén Python thất bại — vui lòng thử lại." >&2; return 1; }
  rm -f ".python/$asset" ".python/SHA256SUMS"
  p="$WS/.python/python/bin/python3.12"
  [ -x "$p" ] || p="$WS/.python/python/bin/python3"
  if ! py_ge_310 "$p"; then
    echo "Python vừa tải không chạy được — vui lòng thử lại." >&2
    return 1
  fi
  echo "$p"
}

# Venv có thể là dây dư từ bản app cũ: tạo bằng python 3.9 hệ thống thì pip
# không bao giờ tìm được vieneu (yêu cầu >= 3.10) — phải xoá và tạo lại
if [ -x "$WS/.venv-engine/bin/python" ] && ! py_ge_310 "$WS/.venv-engine/bin/python"; then
  echo "Venv hiện tại dùng Python quá cũ (< 3.10) — xoá và tạo lại…"
  rm -rf "$WS/.venv-engine"
fi

if [ ! -x "$WS/.venv-engine/bin/python" ]; then
  PY=""
  if [ "${SA_FORCE_MANAGED_PY:-}" != "1" ]; then
    PY=$(find_good_python) && echo "Dùng $($PY --version) trên máy…"
  fi
  if [ -z "$PY" ]; then
    PY=$(install_managed_python) || exit 1
    echo "Dùng $($PY --version) (Python app tự tải vào .python)…"
  fi
  echo "Tạo venv .venv-engine..."
  "$PY" -m venv .venv-engine || exit 1
fi

"$WS/.venv-engine/bin/pip" install --upgrade pip 2>&1 | tail -1
echo "Cài vieneu + edge-tts + kokoro-onnx (tải từ PyPI, có thể mất vài phút)..."
# misaki-fork[en] (G2P tiếng Anh cho engine Kokoro) kéo theo spacy/torch —
# nặng thêm ~1.3GB đĩa nhưng không chiếm RAM khi không dùng Kokoro.
PACKAGES=(vieneu edge-tts kokoro-onnx "misaki-fork[en]")
[ -n "${SA_PACKAGES:-}" ] && read -ra PACKAGES <<< "$SA_PACKAGES"
"$WS/.venv-engine/bin/pip" install "${PACKAGES[@]}" || exit 1
# Prefetch spacy model cho misaki (13MB) — tránh tải lúc nạp engine Kokoro lần đầu
"$WS/.venv-engine/bin/python" -m spacy download en_core_web_sm 2>&1 | tail -1 || true
echo "XONG: runtime đã sẵn sàng tại .venv-engine"
