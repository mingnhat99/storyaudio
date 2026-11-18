#!/usr/bin/env python
"""Dựng audiobook một hồi từ epub bằng VieNeu-TTS (script CLI legacy —
hằng ngày nên dùng app StoryAudio, script này giữ để chạy từng hồi thủ công).

Dùng:  EPUB=<file.epub> caffeinate -is nice -n 20 python audiobook.py <file-html> <ten-file>
Ví dụ: EPUB=sach.epub caffeinate -is nice -n 20 python audiobook.py 1/texts/11.html chuong-11
- Không truyền EPUB: tự dùng file *.epub duy nhất trong workspace.
- Workspace = thư mục chứa script (phải có models/ — tải qua Model Manager của app hoặc
  `huggingface-cli download`). Chạy trong venv đã cài `vieneu` (setup_runtime.sh).
Chạy lại sẽ bỏ qua các đoạn đã xong (resumable).

Biến môi trường:
- EPUB      (bắt buộc nếu workspace có >1 file epub): file sách nguồn.
- VOICE     (mặc định preset turbo đầu tiên engine báo cáo): tên giọng preset.
- REF_AUDIO (mặc định ref-voice.wav): file audio tham chiếu để enroll giọng cho v3nano.
- MODE      (mặc định v3turbo): 'v3nano' = model siêu nhẹ 24kHz, RAM ~1.3GB, chất lượng thấp hơn một chút.
- THREADS   (mặc định 2): thread ONNX intra-op. 0 = mặc định engine (~4-8, nặng máy).
- PART_CHARS (mặc định 4500): đoạn nhỏ -> RAM đỉnh thấp, resume mịn hơn.
- FORMAT    (mặc định m4a): 'mp3' = xuất MP3 bằng lame (afconvert của Apple không encode MP3).
- Gộp WAV kiểu streaming: ghi từng đoạn ra đĩa, không load toàn bộ vào RAM.
"""
import os
# Giới hạn BLAS/OMP TRƯỚC khi import numpy, để numpy/librosa không chiếm hết core
for _v in ("OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS",
           "NUMEXPR_NUM_THREADS", "VECLIB_MAXIMUM_THREADS"):
    os.environ.setdefault(_v, "1")

import gc, resource, sys, time, zipfile
from pathlib import Path

# Workspace = thư mục chứa script (models/, build/, file epub nằm cạnh script)
BASE = Path(__file__).resolve().parent
os.chdir(BASE)
_epubs = sorted(BASE.glob("*.epub"))
EPUB = os.environ.get("EPUB") or (_epubs[0].name if len(_epubs) == 1 else "")
MODE = os.environ.get("MODE", "v3turbo")
VOICE = os.environ.get("VOICE", "")
REF_AUDIO = os.environ.get("REF_AUDIO", "ref-voice.wav")
PART_CHARS = int(os.environ.get("PART_CHARS", "4500"))
THREADS = int(os.environ.get("THREADS", "2"))

# ----ONNX model dùng thư mục local, tránh lỗi symlink của HF cache ----
import huggingface_hub
LOCAL = {"pnnbao-ump/VieNeu-TTS-v3-Turbo": "models/vieneu-backbone",
         "OpenMOSS-Team/MOSS-Audio-Tokenizer-Nano-ONNX": "models/moss-codec-onnx",
         "pnnbao-ump/VieNeu-TTS-v3-Nano": "models/vieneu-nano"}
_orig = huggingface_hub.hf_hub_download
def _patched(repo_id, filename=None, *a, repo_type=None, subfolder=None, **k):
    d = LOCAL.get(repo_id)
    if d:
        p = os.path.join(d, subfolder or "", filename or "")
        if os.path.exists(p):
            return p
    return _orig(repo_id, filename, *a, repo_type=repo_type, subfolder=subfolder, **k)
huggingface_hub.hf_hub_download = _patched


def rss_mb():
    # macOS: ru_maxrss tính bằng byte
    return resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024 / 1024


def load_chapter(ch_file: str):
    import warnings; warnings.filterwarnings("ignore")
    from bs4 import BeautifulSoup
    z = zipfile.ZipFile(EPUB)
    soup = BeautifulSoup(z.read(ch_file), "lxml")
    lines = [l.strip() for l in soup.get_text("\n", strip=True).splitlines() if l.strip()]
    # gộp dòng trùng liền nhau (epub này lặp tiêu đề), tách tiêu đề + 2 câu đối
    dedup = [l for i, l in enumerate(lines) if i == 0 or l != lines[i - 1]]
    header, paras = [], []
    for l in dedup:
        if len(paras) == 0 and len(l) < 60 and not l.endswith((".", "!", "?", "…")):
            header.append(l)
        else:
            paras.append(l)
    return header, paras


def split_parts(paras, limit=PART_CHARS):
    parts, cur, cur_len = [], [], 0
    for p in paras:
        if cur and cur_len + len(p) > limit:
            parts.append("\n".join(cur)); cur, cur_len = [], 0
        cur.append(p); cur_len += len(p)
    if cur:
        parts.append("\n".join(cur))
    return parts


def log(msg):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def main():
    if not EPUB:
        log("Thiếu file EPUB: đặt EPUB=<file.epub> (hoặc để đúng 1 file .epub trong workspace)")
        sys.exit(1)
    if not Path(EPUB).exists():
        log(f"Không thấy file EPUB: {EPUB}")
        sys.exit(1)
    ch_file = sys.argv[1] if len(sys.argv) > 1 else "1/texts/1.html"
    slug = sys.argv[2] if len(sys.argv) > 2 else "chapter-1"
    work = BASE / "build" / slug
    work.mkdir(parents=True, exist_ok=True)

    header, paras = load_chapter(ch_file)
    text_header = ". ".join(header) + "."
    parts = split_parts(paras)
    parts[0] = text_header + "\n" + parts[0]
    log(f"{ch_file}: {sum(len(p) for p in parts):,} ky tu, {len(parts)} doan "
        f"(~{PART_CHARS}/doan), mode={MODE}, threads={THREADS or 'engine-default'}")

    from vieneu import Vieneu
    if MODE == "v3nano":
        tts = Vieneu(mode="v3nano", onnx_dir="models/vieneu-nano", threads=THREADS)
    else:
        tts = Vieneu(mode="v3turbo", onnx_dir="models/vieneu-backbone/onnx_update", threads=THREADS)
    presets = dict(tts.list_preset_voices())
    voice = VOICE or (next(iter(presets)) if presets else "")
    if not voice:
        log("Chưa có giọng đọc: đặt VOICE=<tên giọng> + REF_AUDIO=<file audio tham chiếu> "
            "để enroll giọng, hoặc dùng preset có sẵn của engine")
        sys.exit(1)
    if voice not in presets:
        # Giọng chưa có preset → enroll từ file audio tham chiếu (5–30s, một người nói)
        if not Path(REF_AUDIO).exists():
            log(f"Giọng '{voice}' chưa có preset và không thấy file tham chiếu "
                f"'{REF_AUDIO}' (đặt REF_AUDIO=<file>) -> dừng")
            sys.exit(1)
        t0 = time.time()
        tts.add_voice(voice, REF_AUDIO, denoise=True)
        log(f"enroll giong '{voice}' tu {REF_AUDIO}: {time.time()-t0:.0f}s")
    sr = tts.sample_rate
    log(f"sample rate: {sr}Hz | RAM sau load: {rss_mb():.0f}MB")

    import soundfile as sf
    t_start = time.time()
    total_audio = 0.0
    for i, text in enumerate(parts, 1):
        wav_path = work / f"part-{i:02d}.wav"
        if wav_path.exists() and wav_path.stat().st_size > 1000:
            info = sf.info(wav_path)
            total_audio += info.duration
            log(f"doan {i}/{len(parts)}: DA CO, bo qua ({info.duration:.0f}s)")
            continue
        ok = False
        for attempt in range(1, 4):
            try:
                t0 = time.time()
                wav = tts.infer(text, voice=voice)
                tts.save(wav, str(wav_path))
                dur = len(wav) / sr
                total_audio += dur
                log(f"doan {i}/{len(parts)}: {len(text):,} ky tu -> {dur:.0f}s audio "
                    f"trong {time.time()-t0:.0f}s (tong audio {total_audio/60:.0f} phut, "
                    f"RAM dinh {rss_mb():.0f}MB)")
                del wav
                gc.collect()
                ok = True
                break
            except Exception as e:
                log(f"doan {i}: lan thu {attempt} LOI: {type(e).__name__}: {str(e)[:150]}")
                time.sleep(3)
        if not ok:
            log(f"doan {i} THAT BAI sau 3 lan -> dung lai; chay lai script de tiep tuc")
            sys.exit(1)

    # gộp các đoạn thành một file (streaming: RAM đỉnh chỉ ~1 đoạn)
    import numpy as np
    silence = np.zeros(int(sr * 0.6), dtype="float32")  # nghỉ 0.6s giữa các đoạn
    final_wav = work / f"{slug}.wav"
    with sf.SoundFile(final_wav, "w", samplerate=sr, channels=1, subtype="FLOAT") as fout:
        for i in range(1, len(parts) + 1):
            a, _ = sf.read(work / f"part-{i:02d}.wav", dtype="float32")
            fout.write(a)
            fout.write(silence)
            del a
    fmt = os.environ.get("FORMAT", "m4a").lower()
    out_audio = BASE / f"{slug}.{fmt}"
    if fmt == "mp3":
        title = ". ".join(header)
        os.system(f'lame --quiet -V 2 --tt "{title}" '
                  f'--ta "VieNeu-TTS" "{final_wav}" "{out_audio}"')
    else:
        os.system(f'afconvert -f m4af -d aac "{final_wav}" "{out_audio}"')
    log(f"XONG: {out_audio.name} | audio {total_audio/60:.0f} phut | "
        f"tong thoi gian {(time.time()-t_start)/60:.0f} phut | RAM dinh {rss_mb():.0f}MB")
    log(f"Goi y: xoa thu muc build/{slug}/ sau khi nghe thu de gian dia")


if __name__ == "__main__":
    main()
