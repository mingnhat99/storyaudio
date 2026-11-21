# StoryAudio — App macOS chuyển sách/text thành audio

App desktop native (SwiftUI) bọc pipeline VieNeu-TTS sẵn có của bạn. Mọi tính năng chạy
qua worker Python (`tts_worker.py`) trong venv của thư mục làm việc.

**File app:** `build-app/StoryAudio.app` (đã build + ký ad-hoc; build lại bằng `./make_app.sh`)
**File phát hành:** `build-app/StoryAudio-<version>.dmg` — build bằng `./make_dmg.sh`
(sau `./make_app.sh`; DMG có sẵn shortcut Applications, sắp icon qua Finder)

## Khởi động lần đầu (máy chưa có gì)

**Tự cài vào Applications** — mở app lần đầu từ file .dmg, app sẽ hỏi
*"Chuyển StoryAudio vào Applications?"*: bấm 1 nút là app tự copy vào Applications rồi
khởi động lại từ đó, **không cần kéo thả thủ công**. Từ chối thì app vẫn chạy, nhưng lần
mở sau sẽ hỏi lại cho tới khi cài xong. Nếu đích đã có bản khác phiên bản → bản cũ tự
vào Thùng rác (khôi phục được), bản mới copy đè. Dữ liệu (thư viện, vị trí nghe,
workspace, venv) nằm ngoài app bundle nên chuyển chỗ không mất gì.

> Debug hộp thoại tự cài không cần mount DMG thật:
> `defaults write com.storyaudio.app debugAlwaysOfferInstall -bool true`
> (tắt: `defaults delete com.storyaudio.app debugAlwaysOfferInstall`)

App **không bundle sẵn model** — onboarding 3 bước:

1. **Chọn thư mục làm việc** — nơi chứa `models/`, `books/`, `build/`, `output/`.
   Máy mới: chọn thư mục mới tinh (mặc định đề xuất `~/Documents/StoryAudio`).
   Đã từng dùng bản CLI và có sẵn thư mục chứa model: chọn luôn thư mục đó —
   app tự nhận diện model có sẵn, không tải lại.
2. **Cài runtime** (chỉ máy chưa có venv) — app chạy `setup_runtime.sh`: tạo `.venv-engine`,
   `pip install vieneu edge-tts` từ PyPI (cần mạng, ~2GB).
3. **Chọn & tải model** — 4 lựa chọn:
   - **VieNeu v3-Nano** (~400MB, RAM ~1.4GB, 24kHz, máy yếu) — có clone giọng
   - **VieNeu v3-Turbo** (~610MB, RAM ~4.4GB, 48kHz, chất lượng tốt nhất) — có clone giọng
   - **Kokoro-82M tiếng Anh** (~354MB, RAM ~1.5GB, 24kHz, offline) — 28 giọng Mỹ/Anh,
     cho sách tiếng Anh, không clone giọng
   - **Edge-TTS** (online, miễn phí, không chiếm đĩa, không clone giọng)

   Tải từ Hugging Face, có thanh tiến trình theo file + theo byte, **hủy được, tải lại tự
   resume**. Mạng chậm HF: vào Cài đặt → Nâng cao → điền mirror `https://hf-mirror.com`
   → "Khởi động lại worker ngay".

> **Lưu ý macOS:** lần đầu mở app bằng cách double-click, macOS sẽ hỏi quyền truy cập
> thư mục **Documents** — bấm *Cho phép*. Nếu lỡ từ chối hoặc thấy màn cài runtime dù đã
> có venv: bấm "Chọn lại thư mục" rồi chọn lại thư mục làm việc.

## Sử dụng hằng ngày

### Giao diện (bản macOS chuẩn)
- **Sidebar trái** thay cho tab: mục từng sách (kèm tiến độ audio) + nhóm Công cụ
  (Giọng đọc, Hàng đợi — có badge số job đang chạy, Audio đã tạo, Cài đặt); ô **tìm sách** ngay trong sidebar
- **Menu bar đầy đủ**: File → Nhập sách (⌘O), Dán text (⇧⌘V); menu **Điều khiển** →
  Phát/Tạm dừng (Space), tua ±15s (⌘←/⌘→), chương trước/sau; Cài đặt (⌘,);
  Trợ giúp → Hướng dẫn sử dụng
- Toolbar hợp nhất trên đầu cửa sổ; kéo-thả file vào bất kỳ đâu trong cửa sổ
- Chi tiết sách: bìa lớn, badge ngôn ngữ, **thanh tiến độ x/y chương có audio**,
  nút Nghe nổi bật màu; hàng đợi có card job đang chạy viền màu accent

### Nhập sách
- Kéo-thả **EPUB / PDF / TXT / DOCX** vào cột Thư viện, hoặc nút **+ Nhập sách**
- **Dán text** thành "sách ảo" (nút icon clipboard)
- EPUB chia chương theo TOC/spine; TXT/PDF/DOCX tự dò tiêu đề chương
  (Hồi thứ…, Chương…, Quyển…, Phần…, Chapter…, 第N章…)

### Ngôn ngữ: tiếng Việt 🇻🇳 và tiếng Anh 🇬🇧
- App **tự dò ngôn ngữ sách** khi import (vi / en / zh) — hiển thị badge trên tiêu đề sách
- Sách tiếng Anh tự chia chương kiểu Anh: *Chapter 1, CHAPTER II, Part One, Book Two,
  Prologue, Epilogue, Preface…*
- Tab Giọng đọc có **bộ lọc Tất cả / Tiếng Việt / English**
- Engine Edge-TTS có **47 giọng Anh** đủ biến thể (en-US, en-GB, en-AU, en-CA, en-IN…),
  2 giọng Việt (Hoài My, Nam Minh)
- VieNeu đọc được lẫn Anh–Việt; mở sách tiếng Anh mà đang dùng VieNeu, app hiện gợi ý
  1 nút bấm **"Chuyển sang giọng Anh"** (Edge en-US-Aria)
- Regex chia chương tiếng Việt giờ hiểu cả số viết chữ: "Hồi thứ nhất", "Hồi thứ hai"…

### Dựng audio
- Mở sách → bảng chương: chọn nhiều chương (Cmd-click) → **Dựng audio**
- Hoặc nút **Dựng N chương còn thiếu** để dựng cả quyển
- Menu chuột phải chương: đổi tên, bỏ qua, dựng lại, mở file trong Finder
- **Mở trong Finder**: nút 📁 cạnh mỗi file trong bảng chương, trong tab Audio đã tạo,
  ở thanh player (file đang phát) và nút Mở trong tab Hàng đợi
- Tiến trình trong tab **Hàng đợi**: thanh tiến trình theo đoạn, ETA, RAM worker,
  nút Hủy từng chương, tạm dừng hàng đợi, log worker realtime
- **Đứt giữa chừng (sleep/crash/tắt app): mở lại và dựng tiếp — tự bỏ qua các đoạn đã xong**

### Quản lý audio đã tạo
- Tab **Audio đã tạo** gộp mọi file đã dựng: thời lượng (đo nền), dung lượng, ngày tạo;
  kèm cả file rời rạc trong thư mục output không liên kết chương nào
- **Tìm kiếm** theo tên file/chương/sách, **lọc theo sách**, sắp xếp bấm vào tiêu đề cột
- Chọn nhiều file → mở loạt trong Finder hoặc **chuyển vào Thùng rác**
  (chương tương ứng tự về trạng thái chưa dựng)

### Giọng đọc & clone giọng
- Tab **Giọng đọc**: nghe thử từng giọng (nút ▶), bấm **Dùng** để chọn mặc định
- **Clone giọng**: thả file audio tham chiếu 5–30s (sạch, một người nói) → đặt tên →
  khử ồn tự động → enroll → lưu vĩnh viễn trong engine
- Xuất/nhập giọng clone ra file JSON để sao lưu hoặc chuyển máy
- Giọng mẫu có sẵn tuỳ model (engine VieNeu tải kèm preset, vd "Bảo Khánh Miền Bắc
  Kể Chuyện"); giọng không có preset thì app tự enroll từ file audio tham chiếu của bạn
  (làm 1 lần, lưu lại cho các lần chạy sau)

### Nghe trong app
- Player dưới đáy cửa sổ: play/pause (Space), ±15s, chương trước/sau
- **Tua 0.5×–3× không méo giọng**; kéo thanh tua chỉ tua thật khi thả tay (không giật)
- **Âm lượng riêng của app** (slider cạnh thanh tua, nhớ lại lần sau; bấm icon loa để tắt/bật tiếng)
- **Media key & Control Center**: F7–F9 / tai nghe điều khiển phát–dừng, tua ±15s, chuyển chương
- Tự **nhớ vị trí đang nghe** từng sách; bookmark kèm ghi chú
- **Tiếp tục nghe sau khi đóng app**: mở lại app, thanh player hiện ngay ở vị trí
  nghe lần trước (đang tạm dừng — bấm play là nghe tiếp); màn Thư viện có card
  "Tiếp tục nghe" để phát tiếp nhanh
- **Sleep timer**: 10–90 phút hoặc hết chương — đang bật hiện đếm ngược phút trên icon trăng
- Bấm vào tổng thời gian để đổi sang **thời gian còn lại**; badge `n/total` cho biết vị trí chương
- File audio lỗi/bị xóa hiện **cảnh báo cam** trên thanh player

### Cài đặt đáng chú ý
- **Engine**: VieNeu Turbo/Nano, Kokoro (sách tiếng Anh, offline) hoặc Edge-TTS
  (đổi là nạp lại engine ngay)
- **Tự dò cấu hình máy** → chọn mode/threads/part_chars theo bảng đo trong
  `HUONG-DAN-AUDIOBOOK.md`; có nút áp dụng lại
- **Tốc độ**: nano đổi được tốc độ khi dựng (0.7–1.5×); Edge có rate ±%; turbo đổi
  tốc độ lúc nghe (player)
- **Xuất file**: M4A/MP3/WAV; thư mục đích; mẫu tên `{book} - {index:02d}. {title}`
- **Quy tắc tìm–thay thế** (toàn cục + theo sách): sửa tên riêng/từ cứng trước khi dựng
- Nâng cao: temperature/top-K/phạt lặp; khởi động lại worker sau mỗi chương (giải phóng RAM);
  **nghỉ làm mát** giữa các chương trong hàng đợi (0–30 phút, mặc định tắt) — dựng liên tục
  nhiều chương làm nóng máy thì app chờ máy nguội bớt rồi mới dựng chương kế, bỏ nghỉ được bất cứ lúc nào

## Gỡ cài đặt

Hai cách:

1. **Trong app**: Cài đặt → tab Nâng cao → mục Dữ liệu → **"Gỡ cài đặt StoryAudio…"**
   — cửa sổ chọn từng thành phần:
   - ✅ Dữ liệu app (thư viện, vị trí nghe, bookmark, cài đặt) — mặc định
   - ✅ Đưa `StoryAudio.app` vào **Thùng rác** (khôi phục được) — mặc định
   - ⬜ Sách đã import + audio trong `output/` + file đoạn tạm `build/`
   - ⬜ Model TTS trong `models/` (~610MB, tải lại được qua Model Manager)
   - ⬜ `.venv-engine` (venv app tự tạo trên máy mới)
   - ⬜ File worker app copy vào thư mục làm việc (`tts_worker.py`, `catalog.json`,
     `setup_runtime.sh`)
   - Có xác nhận 2 bước; cảnh báo orange cho mục mất dữ liệu không hồi phục

2. **Terminal**: `./uninstall.sh` — cờ `--data-only` (chỉ dữ liệu app), `--all`
   (xóa cả sách/audio/model/venv), `--no-app` (giữ lại app)

> Bộ gỡ cài đặt **không bao giờ đụng** đến file gốc của bạn: epub gốc, audio đã xuất
> nằm ngoài `output/`, file audio tham chiếu giọng đọc (`ref-*.wav`), backup JSON,
> `audiobook.py`, `HUONG-DAN-AUDIOBOOK.md`…

## Cấu trúc dữ liệu

```
<thư mục làm việc>/
├── models/          # model TTS (tải qua Model Manager)
├── books/<id>/      # mỗi sách: book.json + chapters/NNN.txt + cover + source copy
├── build/<slug>/    # part-XXX.wav tạm (resumable) — tự dọn khi xong nếu bật
├── output/          # file audio hoàn chỉnh (mặc định)
└── .venv-engine/    # (máy mới) venv python do app tạo

~/Library/Application Support/StoryAudio/
├── settings (UserDefaults)  # cài đặt
├── library.json             # trạng thái chương (đã có audio, bỏ qua, tên đổi)
├── positions.json           # vị trí đang nghe
└── bookmarks.json
```

## Xử lý sự cố

| Triệu chứng | Cách xử lý |
|---|---|
| Màn "Cài runtime" dù đã có venv | macOS chặn quyền thư mục → "Chọn lại thư mục" |
| Worker chết giữa chừng | App tự restart worker + tải lại engine + chạy tiếp đoạn dở (tối đa 3 lần) |
| Tải model chậm/kẹt | Cài đặt → Nâng cao → mirror `https://hf-mirror.com` → restart worker |
| Xuất MP3 lỗi `lame` | Cài lame: `brew install lame` |
| Muốn render lùi về chế độ cũ (CLI) | `audiobook.py` vẫn dùng song song được — không xung đột |

## Kiểm thử tự động

```bash
app/.build/debug/StoryAudio --smoke-render <file-sách-nhỏ>
# chạy nguyên luồng app không GUI: bootstrap → import → render chương nhỏ nhất → exit 0/1
```
