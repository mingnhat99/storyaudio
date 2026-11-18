# StoryAudio

**StoryAudio** is a native macOS app (SwiftUI) that turns EPUB / PDF / TXT / DOCX books
into audiobooks **entirely on your machine** — no cloud TTS required. It drives local
neural TTS engines through a Python worker and ships with a full-featured audiobook player.

> 🇻🇳 Bản tóm tắt tiếng Việt nằm ở [phần cuối](#tiếng-việt).

## Features

- **Import books**: EPUB / PDF / TXT / DOCX (drag & drop) or paste raw text into a virtual book.
  Automatic chapter detection for Vietnamese (`Hồi thứ…`, `Chương…`, `Quyển…`), English
  (`Chapter 1`, `Part One`, `Prologue`…) and Chinese (`第N章`) headings.
- **Render queue with resume**: each ~4.5k-char part is a separate `part-XXX.wav` — a crash,
  macOS sleep or app restart just skips finished parts and continues. Progressive listening:
  play parts as soon as they're rendered, with a stepped ramp so the first audio is ready fast.
- **Voice cloning** (VieNeu engines): enroll a voice from a 5–30s clean reference clip with
  automatic denoising; voices persist in the engine and can be exported/imported as JSON.
- **Built-in player**: 0.5×–3× speed without pitch distortion, per-book playback positions,
  bookmarks with notes, sleep timer, media keys & Control Center, "continue listening" across
  app restarts.
- **Output**: M4A / MP3 / WAV, configurable naming pattern and destination folder;
  global + per-book find-and-replace text rules (fix names, hard words before rendering).
- **Multi-engine**, downloaded on demand from Hugging Face (never bundled):

  | Engine | Language | Size | Peak RAM | Notes |
  |---|---|---|---|---|
  | VieNeu-TTS v3-Nano | 🇻🇳 vi (+en) | ~400 MB | ~1.4 GB | 24 kHz, 1 CPU core, runs on weak machines, voice cloning |
  | VieNeu-TTS v3-Turbo | 🇻🇳 vi (+en) | ~610 MB | ~4.4 GB | 48 kHz, best quality, voice cloning |
  | Kokoro-82M (ONNX) | 🇬🇧 en | ~354 MB | ~1.5 GB | Fully offline, 28 US/UK voices |
  | Edge-TTS | 🇻🇳 / 🇬🇧 | 0 MB | ~0.2 GB | Free Microsoft neural voices (online) |

## Requirements

- macOS 14+ (Apple Silicon recommended; benchmarks in the docs are from an M2)
- Python 3.11 or 3.12 (from [python.org](https://python.org) or Homebrew)
- `lame` — optional, only for MP3 export: `brew install lame`
- Swift 5.9 toolchain (Xcode 15+) to build from source

## Build & run

```bash
git clone https://github.com/mingnhat99/storyaudio.git
cd storyaudio
./make_app.sh                    # swift build -c release → build-app/StoryAudio.app (ad-hoc signed)
open build-app/StoryAudio.app
```

First launch onboarding (3 steps):

1. **Pick a workspace folder** — where `models/`, `books/`, `build/`, `output/` live
   (default suggestion: `~/Documents/StoryAudio`).
2. **Install runtime** — the app runs `setup_runtime.sh`, which creates a `.venv-engine`
   and `pip install`s the engine packages from PyPI (~2 GB, one time).
3. **Pick & download a model** — progress per file and per byte, cancellable, resumable.
   On a slow connection to Hugging Face, Settings → Advanced has an HF mirror option.

Daily driving is GUI-only — see [`README-APP.md`](README-APP.md) for the full manual
(also reachable from the app's Help menu when it sits in the workspace folder).

## How it works

```
StoryAudio.app (SwiftUI, SwiftPM — no external dependencies)
   │  JSON lines over stdin/stdout
   ▼
tts_worker.py (Python, spawned as a separate low-priority process)
   │  local model dirs under <workspace>/models/ (offline after download)
   ▼
ONNX TTS engines: VieNeu-TTS · Kokoro-82M · Edge-TTS
```

The worker is resumable per part, streams WAV concatenation to disk (constant peak RAM),
reports progress/RAM/CPU events back to the UI, and is restarted automatically by the app
if it dies mid-job. [`HUONG-DAN-AUDIOBOOK.md`](HUONG-DAN-AUDIOBOOK.md) documents the
engineering notes and real-world benchmarks (M2: turbo ~1.7× realtime, nano ~1.3× realtime
on a single core).

### CLI (legacy)

`audiobook.py` renders a single chapter from an EPUB straight from the terminal —
the pipeline the app was built around. Usage and tuning knobs (`MODE`, `THREADS`,
`PART_CHARS`, `FORMAT`, `VOICE`, `REF_AUDIO`) are in the script header and in
[`HUONG-DAN-AUDIOBOOK.md`](HUONG-DAN-AUDIOBOOK.md).

### Workspace layout

```
<workspace>/
├── models/          # TTS models (downloaded via Model Manager)
├── books/<id>/      # book.json + chapters/NNN.txt + cover per imported book
├── build/<slug>/    # resumable part-XXX.wav temp files
├── output/          # finished audio files
└── .venv-engine/    # Python venv created by setup_runtime.sh
```

App data (library state, positions, bookmarks, settings) lives in
`~/Library/Application Support/StoryAudio/`.

## Model licenses & attribution

Models are downloaded at runtime and governed by **their own licenses** — see the
`license_url` field of each entry in [`catalog.json`](catalog.json) / `app/Sources/StoryAudio/Resources/catalog.json`.
The app shows a license consent screen before first use. Kokoro-82M is Apache-2.0;
VieNeu-TTS and MOSS-Audio-Tokenizer carry the licenses set by their publishers on
Hugging Face; Edge-TTS is a free Microsoft online service governed by Microsoft's terms.

## Privacy

Rendering and voice cloning run **fully locally** — your books, audio output and
cloned-voice data never leave your machine. The only exception is the Edge-TTS engine,
which sends text to Microsoft's online service by design.

## Copyright note

This repository contains **source code only** — no books, no audio, no model weights.
Please only convert books you have the right to use, and respect your local copyright law.

## License

[MIT](LICENSE) © 2026 Nguyen Minh Nhat

---

## Tiếng Việt

**StoryAudio** là app macOS native (SwiftUI) chuyển sách EPUB / PDF / TXT / DOCX thành
audiobook **ngay trên máy bạn** — không cần cloud. App điều phối các engine TTS neural
chạy local qua một Python worker, kèm player audiobook đầy đủ tính năng.

**Tính năng chính:**

- Nhập sách EPUB / PDF / TXT / DOCX (kéo-thả) hoặc dán text; tự dò chia chương tiếng Việt,
  Anh, Trung.
- Hàng đợi dựng audio **resumable theo từng đoạn** — crash/máy ngủ/tắt app chỉ cần mở lại
  là dựng tiếp; vừa dựng vừa nghe được (nghe dần không phải chờ xong cả chương).
- **Clone giọng** từ 5–30s audio tham chiếu (tự khử ồn), lưu vĩnh viễn, xuất/nhập JSON.
- Player trong app: tua 0.5×–3× không méo giọng, nhớ vị trí từng sách, bookmark, sleep
  timer, media key/Control Center, mở lại app là nghe tiếp chỗ đang dở.
- Xuất M4A / MP3 / WAV; quy tắc tìm–thay thế text (toàn cục + theo sách).

**Engine** (tải theo yêu cầu từ Hugging Face, không bundle sẵn): VieNeu-TTS v3-Nano
(24kHz, máy yếu, có clone giọng) · v3-Turbo (48kHz, chất lượng cao nhất, có clone giọng) ·
Kokoro-82M (tiếng Anh offline) · Edge-TTS (online, miễn phí).

**Chạy thử:**

```bash
./make_app.sh && open build-app/StoryAudio.app
```

Lần đầu: chọn thư mục làm việc → app tự cài runtime Python (`.venv-engine`) → chọn và tải
model. Hướng dẫn sử dụng đầy đủ bằng tiếng Việt trong [`README-APP.md`](README-APP.md).

**Lưu ý:** repo này chỉ chứa **mã nguồn** — không có sách, audio hay model weights. Model
do người dùng tự tải và chịu license riêng của từng model (xem `catalog.json`). Vui lòng
chỉ chuyển sách mà bạn có quyền sử dụng. Mã nguồn phát hành theo giấy phép [MIT](LICENSE).
