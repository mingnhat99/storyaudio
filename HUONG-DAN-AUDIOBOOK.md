# Hướng dẫn dựng audiobook VieNeu-TTS — Ghi chú & Best Practice

Cập nhật lần cuối: 2026-10-27 (đã có **app desktop StoryAudio** — xem ghi chú đầu trang; script CLI bên dưới vẫn dùng song song được)

> **Nên dùng app StoryAudio cho hằng ngày** (`build-app/StoryAudio.app`,
> hướng dẫn chi tiết trong `README-APP.md`). App wrap nguyên pipeline này: chia chương từ
> EPUB/PDF/TXT/DOCX, hàng đợi render resumable (part-XXX.wav như cũ), clone giọng qua UI,
> tải model từ internet theo yêu cầu (không bundle sẵn), player tua tốc độ không méo giọng,
> nhớ vị trí nghe từng sách. Các khuyến nghị kiến trúc ở mục dưới đã được app thực hiện đúng:
> worker process riêng (nice -n 20), resumable theo đoạn, preset theo máy, chống ngủ
> (beginActivity), gộp streaming, log RAM/CPU. Script `audiobook.py` giữ nguyên để chạy CLI.

## Tóm tắt môi trường (chỉ cần làm 1 lần)

- Truyện: file `.epub` của bạn (script đọc trực tiếp chương dạng HTML bên trong epub)
- TTS: thư viện `vieneu` (VieNeu-TTS-v3, chế độ ONNX chạy CPU) trong venv —
  tạo nhanh bằng `./setup_runtime.sh <workspace>` (tạo `.venv-engine`)
- Model tải về local qua Model Manager của app hoặc `huggingface-cli`:
  `models/vieneu-backbone/` (backbone + denoiser + speaker encoder)
  và `models/moss-codec-onnx/` (audio codec) — sau đó **không cần mạng khi chạy**
- Giọng đọc: preset có sẵn của engine, hoặc giọng riêng enroll từ file audio tham chiếu
  (biến `REF_AUDIO`, 5–30s audio sạch một người nói)
- Script dựng: `audiobook.py`

## Chạy 1 lệnh cho chương tiếp theo

```bash
cd <thư-mục-workspace>   # thư mục chứa audiobook.py, models/ và file epub
# chế độ thường (v3turbo, 48kHz, chất lượng cao):
EPUB=sach.epub caffeinate -is nice -n 20 .venv-engine/bin/python audiobook.py 1/texts/13.html chuong-13 \
  2>&1 | tee build-chuong-13.log
# chế độ siêu nhẹ (v3nano, 24kHz, RAM ~1.3GB, 1 core):
EPUB=sach.epub MODE=v3nano PART_CHARS=2500 THREADS=1 caffeinate -is nice -n 20 \
  .venv-engine/bin/python audiobook.py 1/texts/13.html chuong-13 2>&1 | tee build-chuong-13.log
# xuất MP3 thay vì m4a (dùng được cho cả turbo lẫn nano): thêm FORMAT=mp3
EPUB=sach.epub FORMAT=mp3 caffeinate -is nice -n 20 .venv-engine/bin/python audiobook.py 1/texts/13.html chuong-13
# giọng riêng (không nằm trong preset engine): thêm VOICE=Tên-gióng REF_AUDIO=ref-voice.wav
```

- Đổi `1/texts/13.html` / `chuong-13` theo chương cần dựng (đường dẫn HTML nằm bên trong epub).
  Kết quả: `chuong-13.m4a` ngay trong workspace.
- Giọng không có preset trong engine sẽ được tự enroll từ `REF_AUDIO` lúc khởi động.
- Chạy giữa chừng bị dắt máy mạng/crash → chỉ cần **chạy lại đúng lệnh**, các đoạn đã xong
  trong `build/<slug>/part-*.wav` sẽ tự bỏ qua (resumable).
- Muốn nhanh hơn, chấp nhận nặng máy: thêm `THREADS=4` hoặc `THREADS=0` (engine tự chọn) vào
  đầu lệnh; muốn RAM thấp hơn nữa: `PART_CHARS=3000`.

## Tham số tiết kiệm CPU/RAM (mặc định hiện tại)

| Tham số | Mặc định | Ý nghĩa |
|---|---|---|
| `THREADS` | 2 | Số thread ONNX. 0 = engine mặc định (~4–8, chiếm gần hết CPU M2). 2 = máy vẫn dùng được việc khác, chạy chậm hơn |
| `PART_CHARS` | 4500 | Số ký tự mỗi đoạn. Đoạn nhỏ → RAM đỉnh thấp, resume mịn. (Hồi 10 từng dùng 9000) |
| `nice -n 20` | — | Chạy ưu tiên thấp, không giật máy |
| `caffeinate -is` | — | Chặn Mac ngủ khi đang dựng (quan trọng với bản chạy hàng giờ) |
| `FORMAT` | m4a | `mp3` = xuất MP3 bằng `lame` (đã cài qua Homebrew, bản 3.100). `-V 2` VBR mono → ~70kbps với giọng đọc, 118 phút ≈ 30MB, encode chỉ ~15s |
| `OMP/BLAS...=1` | tự set trong script | Chặn numpy/librosa chiếm thêm core |

Trên MacBook M2 (4 hiệu năng + 4 tiết kiệm, 16GB RAM): RAM đỉnh của tiến trình chỉ
vài trăm MB lúc infer; lúc gộp file chỉ ~1 đoạn audio trong RAM (~70MB).

## Các vấn đề đã gặp & cách khắc phục

1. **HF Hub lỗi symlink / tải lại model mỗi lần chạy** → script vá `hf_hub_download`
   trỏ về thư mục `models/` local. Sau khi có local model, chạy offline hoàn toàn.
2. **Chạy Hồi 10 bị đứt giữa chừng** (đoạn 7, sau ~35 phút im lặng — nghi do máy ngủ
   hoặc tiến trình bị kill) → hai biện pháp: `caffeinate` chống ngủ + thiết kế resumable
   từng đoạn (mỗi đoạn 1 file `part-XX.wav`, chạy lại bỏ qua đoạn xong).
3. **Gộp file tốn ~3GB RAM** (bản cũ load toàn bộ 11 đoạn + concatenate = 2 bản sao
   của ~125 phút audio float32 vào RAM) → giờ ghi streaming từng đoạn ra đĩa bằng
   `sf.SoundFile`, RAM đỉnh lúc gộp chỉ còn ~1 đoạn.
4. **CPU mặc định của engine dùng ~4–8 thread** khiến máy nóng/khó dùng việc khác →
   `THREADS=2` + `nice -n 20`; đánh đổi thời gian dài hơn (chấp nhận chậm).
5. **Đoạn 9000 ký tự hơi to** (một đoạn lỗi là mất ~7 phút infer để làm lại) → giảm còn
   4500, mất mát khi làm lại nhỏ hơn và RAM đỉnh thấp hơn.
6. Warning "unauthenticated requests to the HF Hub" khi khởi động là vô hại (chỉ check
   version metadata); model vẫn load từ local.
7. **Bẫy khi theo dõi tiến trình bằng `pgrep -f`**: các tiến trình bọc ngoài (zsh -c,
   caffeinate) cũng chứa chuỗi lệnh khớp pattern và có PID thấp hơn → bắt nhầm (thấy
   CPU/RAM = 0). Khắc phục: chọn tiến trình khớp có **RSS lớn nhất** (worker thật ~3,6GB,
   wrapper chỉ vài trăm KB). Trong app desktop nên giữ PID của worker do chính app spawn.
8. **v3nano cần model riêng** (repo `pnnbao-ump/VieNeu-TTS-v3-Nano`): tải về
   `models/vieneu-nano/` (~360MB) + copy `denoiser.onnx` từ turbo sang. Nano không có
   sẵn preset giọng preset của turbo → script tự enroll từ `REF_AUDIO` (~4–8s).
9. **Sample rate khác nhau giữa mode** (turbo 48kHz, nano 24kHz): script giờ lấy
   `tts.sample_rate` động; đừng hardcode 48000 khi viết app.
10. **MP3: afconvert của Apple KHÔNG encode được MP3** (chỉ decode/encode AAC, ALAC…).
    Máy đã có `lame` 3.100 (Homebrew) — script dùng `lame -V 2` khi `FORMAT=mp3`.
    Format xuất độc lập với model: mp3 dùng được cho cả v3turbo và v3nano. Chuyển file
    WAV đã gộp sẵn sang mp3: `lame --quiet -V 2 build/Hoi-thu-XX/Hoi-thu-XX.wav out.mp3`
    (chỉ mất ~15s cho 2 tiếng audio; chuyển từ WAV gốc tốt hơn chuyển qua lại từ m4a).

## Số liệu đo thực tế trên MacBook M2 (8 core, 16GB RAM) — hồi 11

Số liệu chi tiết mỗi 30 giây: `build-hoi-11-resources.log` (turbo) và
`build-hoi-12-resources.log` (nano) — cột: giờ, CPU%, RSS MB.

| Chỉ số | Giá trị đo | Ghi chú |
|---|---|---|
| CPU khi THREADS=2 | trung bình **163%** (≈1,6 core), đỉnh ~198% | Máy vẫn dùng mượt việc khác nhờ thêm `nice` |
| RAM nền sau khi load model | ~2,8–3,6 GB | Trọng số backbone + codec ONNX + bộ đệm |
| RAM đỉnh lúc infer (đoạn 4500 ký tự) | **4,4 GB** (ru_maxrss), mẫu 30s thấy tối đa 4,1 GB | Tăng dần 3,7→4,4GB ~10 đoạn đầu rồi dừng |
| Tốc độ THREADS=2 | ~350s audio / ~170–220s infer ≈ **1,6–1,8× realtime** | |
| Tốc độ threads mặc định (~4–8, hồi 10) | ~710s audio / ~390s infer ≈ 1,8× realtime | |
| **Kết luận quan trọng** | THREADS=2 cho tốc độ **gần bằng** dùng gần hết CPU | Workload giới hạn bởi **băng thông RAM**, không phải số core → thêm thread quá 2–4 gần như không nhanh hơn trên M2 |

| Hồi | Cấu hình | Kết quả | Thời gian |
|---|---|---|---|
| 10 | 93.640 ký tự, 11 đoạn × 9000, threads mặc định | 125 phút audio | ~31 phút infer (2 lần chạy do đứt giữa chừng) |
| 11 | 91.816 ký tự, 22 đoạn × 4500, v3turbo, THREADS=2, nice+caffeinate | **121,5 phút audio** (file m4a 59MB) | **76 phút, 1 lần chạy liền mạch, 22/22 đoạn không lỗi** |
| 12 | 85.966 ký tự, 37 đoạn × 2500, **v3nano**, THREADS=1, nice+caffeinate | **118 phút audio** (m4a 29MB, 24kHz) | **85 phút, 37/37 đoạn không lỗi** |
| 13 | 92.685 ký tự, 21 đoạn × 4500, v3turbo, THREADS=2, nice+caffeinate, **FORMAT=mp3** | **121,6 phút audio** (mp3 90MB, VBR ~98kbps từ WAV 48kHz) | **51 phút, 21/21 đoạn không lỗi** |

## So sánh v3turbo vs v3nano (đo thực tế trên M2, nguyên 1 hồi truyện)

| Chỉ số | v3turbo (hồi 11, 2 thread) | v3nano (hồi 12, 1 thread) |
|---|---|---|
| RAM đỉnh (ru_maxrss) | 4.398 MB | **1.351 MB (giảm 69%)** |
| RAM sống lúc infer | 3,1–3,6 GB | **0,36–0,6 GB** (nano trả RAM sạch giữa các đoạn) |
| CPU trung bình | 163% (~1,6 core) | **96% (đúng 1 core)** |
| Tốc độ trung bình | ~1,7× realtime | ~1,3× realtime (dao động 0,9–2,0×) |
| Chất lượng | 48kHz, tốt hơn (đặc biệt tiếng Anh/lẫn mã) | 24kHz, tiếng Việt vẫn rõ (nghe thử demo trong app để so sánh) |
| Model trên đĩa | ~608 MB | ~360 MB (`models/vieneu-nano/`, đã copy thêm denoiser của turbo) |
| Giọng preset của turbo | có sẵn | nano không có → enroll từ `REF_AUDIO` (~4–8s lúc khởi động) |

**Kết luận cho việc chọn mode:**
- Máy ≥ 8GB RAM: dùng `v3turbo` THREADS=2 — chất lượng tốt nhất, RAM đỉnh ~4,4GB vẫn an toàn.
- Máy 4–8GB RAM hoặc cần chạy song song app khác: `v3nano` THREADS=1 — RAM đỉnh ~1,4GB,
  chỉ 1 core, tốc độ vẫn ~1,3× realtime; chất lượng tiếng Việt chấp nhận được (24kHz).
- v3nano với 1 thread chỉ chậm ~12% so với v3turbo 2 thread (85 vs 76 phút cho lượng text tương đương).

- Sau khi nghe thử ưng ý, có thể xóa `build/Hoi-thu-XX/` (~1,4GB mỗi hồi) để giải phóng đĩa.

## Nghe dần trong khi dựng (progressive listening) — có từ app StoryAudio

Worker vốn ghi từng `part-NNN.wav` xuống đĩa ngay khi xong — app giờ phát luôn các part này
theo thứ tự (chèn đúng khoảng lặng `silence_s` giữa các part) nên timeline sống **trùng khớp
tuyệt đối** với file cuối: nhớ vị trí/bookmark/handover không lệch giây nào.

**Part bậc thang để chờ ít**: job gửi `part_ramp=[700, 1200, 2000]` — 3 part đầu nhỏ dần rồi
về `part_chars` bình thường (vẫn chỉ cắt ở ranh giới đoạn văn nên không đổi chất lượng).
Tính từ tỷ lệ đo ~12,8 ký tự/giây audio:

| Máy / mode | Chờ đoạn đầu | Nghe được ngay |
|---|---|---|
| M2 nano 2 thread (đo 28/10: 3,4x realtime) | **~16 giây** | ~55 giây |
| M2 turbo 2 thread (~1,7x realtime) | ~30–35 giây | ~55 giây |
| Máy yếu nano 1 thread (~1,3x realtime) | ~42–55 giây | ~55 giây |
| Edge-TTS | ~2–5 giây | ~55 giây |

**Điều kiện bắt đầu phát**: part 1 đã có + vận tốc render đo được (EMA `part_audio_sec /
part_seconds` từ event) ≥ **1,15 × tốc độ phát**. Render nhanh hơn nghe (r ≥ 1) thì buffer
chỉ tăng dần — không bao giờ hết; nghe nhanh hơn render (vd 2x trên nano) sẽ gặp chỗ chờ.

**Nghe hết mà chưa có đoạn tiếp (underrun)**: player vào trạng thái chờ, hiện đếm ngược
"Đang dựng đoạn tiếp (~Xs)" (ETA = EMA giây render × tỷ lệ ký tự), part mới đáp xuống là
tự phát tiếp. Cơ chế này cũng phục hồi các trường hợp worker restart vì RAM / crash —
parts cũ bị skip, event tiếp tục đến.

**Hoàn tất**: khi worker trả file cuối, player chuyển sang file đó ngay tại ranh giới part
đang nghe (seek đúng offset tích luỹ) — không nghe lại đoạn nào; build dir được dọn sau đó.
Worker còn phát `render_stage` (`concat`/`encode`) để UI nói đúng "Đang ghép & nén file cuối…"
trong lúc chờ.

Manifest `build/<slug>/parts.json` (ghi atomic sau mỗi part) cho app biết part nào sẵn sàng,
độ dài bao nhiêu; đổi `part_chars`/`part_ramp`/`silence_s` so với lần dựng dở thì worker tự
xóa build dir dựng lại (tránh resume lệch bố cục).

## Gợi ý cấu hình theo máy (dùng cho app desktop tương lai)

Nguyên tắc từ số đo trên M2: model chiếm ~3GB RAM là sàn cố định; tốc độ không scale
theo thread quá 2–4; ưu tiên giữ máy dùng được việc khác hơn là tối đa tốc độ.

| Loại máy | Mode / THREADS | PART_CHARS | Ghi chú |
|---|---|---|---|
| Yếu (4 core, 4–8GB RAM) | **v3nano**, THREADS=1 | 2500 | Đã đo (hồi 12): RAM đỉnh 1,35GB, 1 core — đây là cấu hình cho máy yếu |
| Trung bình (M1/M2 8 core, 8–16GB) | v3turbo, THREADS=2 | 4500 | Cấu hình mặc định của script (đã đo ở hồi 11) |
| Mạnh (M Pro/Max, ≥16GB) | v3turbo, THREADS=4 | 6000–9000 | Quá 4 thread lợi ít (đo trên M2); tăng PART_CHARS để bớt số lần ghi đĩa |

Kiến trúc nên dùng trong app desktop:
1. **Chạy TTS trong process riêng (worker)**, không phải thread trong app: hết/OOM thì
   kill và relaunch được (RAM trả lại OS sạch sẽ), app chính không chết theo; cũng cho
   phép "restart process mỗi N đoạn" nếu RAM tăng dần (hiện tượng creep 3,7→4,3GB).
2. **Resumable theo đoạn** như script hiện tại: mỗi đoạn 1 file `part-XX.wav` — crash/doạn
   lỗi chỉ mất đúng đoạn đó. Đây là lý do hồi 10 chạy lại không mất công đã làm.
3. **Tự dò máy rồi chọn preset**: `os.cpu_count()`, `hw.memsize`, RAM khả dụng
   (`memory_pressure`/`vm_stat`) → chọn dòng trong bảng trên; cho người dùng ghi đè.
4. **Chống ngủ máy**: macOS dùng `ProcessInfo.processInfo.beginActivity(...)` thay cho
   lệnh `caffeinate` (giữ nguyên khi chạy bằng CLI).
5. **Ưu tiên thấp**: worker chạy QoS background (CLI: `nice -n 20`) để không giật UI.
6. **Gộp file streaming** (ghi từng đoạn ra đĩa bằng `soundfile.SoundFile`) — tuyệt đối
   không load toàn bộ audio vào RAM (bản cũ tốn thêm ~3GB lúc ghép).
7. **Ghi log tài nguyên** (CPU%/RSS mỗi 30s như `build-hoi-11-resources.log`) để có dữ
   liệu phản hồi khi tối ưu tiếp, nhất là trên máy thật của người dùng.
8. Hướng khai thác thêm (chưa thử): tắt/t thu nhỏ memory arena của ONNX Runtime
   (`enable_cpu_mem_arena`, shrinkage) nếu vieneu cho truyền SessionOptions; đo lại RAM
   nền có khi hạ được dưới 3GB.

## Checklist lần sau

1. Kiểm tra còn ổ đĩa trống ≥ 5GB (`df -h .`).
2. Chạy lệnh ở mục "Chạy 1 lệnh", để terminal mở (hoặc dùng `nohup ... &`).
3. Xong thì nghe thử file m4a, ưng thì xóa thư mục `build/`.
4. Ghi thêm vấn đề mới (nếu có) vào file này.
