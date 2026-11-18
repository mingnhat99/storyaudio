#!/usr/bin/env python
"""Worker TTS cho app StoryAudio — giao tiếp với app Swift bằng JSON-lines qua stdin/stdout.

Mỗi dòng gửi vào stdin là 1 lệnh:  {"id": <số>, "cmd": "...", ...tham số}
Phản hồi trên stdout:              {"id": <số>, "ok": true/false, "data"/"error": ...}
Sự kiện (progress...) trên stdout: {"event": "...", ...}
Log thường ghi ra stderr (app lưu để hiển thị).

Lệnh xử lý tức thì (main thread): ping, hello, sysinfo, init, model_catalog, model_status,
  cancel, model_download_cancel, list_voices, preview, clone_voice, delete_voice,
  export_voices, import_voices
Lệnh xếp hàng (executor thread, chạy tuần tự): model_download, model_delete, engine_load,
  engine_unload, parse_book, import_text, render

Chạy thử từ terminal:
  echo '{"id":1,"cmd":"hello"}' | .venv-vieneu/bin/python tts_worker.py --workspace .
"""
import argparse
import gc
import json
import os
import queue
import re
import shutil
import subprocess
import sys
import threading
import time
import zipfile
from pathlib import Path

# Giới hạn BLAS/OMP trước khi import numpy để không chiếm hết core (như audiobook.py)
for _v in ("OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS",
           "NUMEXPR_NUM_THREADS", "VECLIB_MAXIMUM_THREADS"):
    os.environ.setdefault(_v, "1")

# Repo HF -> thư mục local trong workspace; vá hf_hub_download để engine chạy offline
LOCAL_REPO_MAP = {
    "pnnbao-ump/VieNeu-TTS-v3-Turbo": "models/vieneu-backbone",
    "OpenMOSS-Team/MOSS-Audio-Tokenizer-Nano-ONNX": "models/moss-codec-onnx",
    "pnnbao-ump/VieNeu-TTS-v3-Nano": "models/vieneu-nano",
}

_state = {
    "workspace": None,   # Path thư mục làm việc (models/, books/, build/)
    "catalog": None,     # dict catalog.json
    "engine_kind": None, # "vieneu" | "edge" | "kokoro"
    "tts": None,         # instance Vieneu (vieneu) hoặc Kokoro (kokoro)
    "mode": None,
    "kokoro_g2p": None,  # misaki en.G2P của engine kokoro (None → dùng phonemize espeak built-in)
    "cancel_flags": {},  # key "dl:<id>" / "job:<id>" -> threading.Event
    "custom_voice_names": set(),  # tên giọng clone của mode đang nạp (đánh dấu custom)
}

_out_lock = threading.Lock()


def send(obj: dict):
    with _out_lock:
        try:
            sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
            sys.stdout.flush()
        except (BrokenPipeError, OSError):
            # app đã đóng pipe (thoát/crash) — không chết vì việc này
            pass


def reply(req_id, ok=True, **data):
    if ok:
        send({"id": req_id, "ok": True, "data": data})
    else:
        err = data.pop("error", "lỗi")
        payload = {"id": req_id, "ok": False, "error": err}
        payload.update(data)  # kèm thông tin phụ (vd model_missing)
        send(payload)


def event(name, **kw):
    send({"event": name, **kw})


def log(msg):
    sys.stderr.write(f"[{time.strftime('%H:%M:%S')}] {msg}\n")
    sys.stderr.flush()


class Cancelled(Exception):
    pass


class ModelMissingError(RuntimeError):
    def __init__(self, model_id, missing):
        super().__init__(f"Model '{model_id}' chưa tải về")
        self.model_id, self.missing = model_id, missing


def ws() -> Path:
    w = _state["workspace"]
    if not w:
        raise RuntimeError("Chưa init {workspace}")
    return Path(w)


# ─────────────────────────── Model manager ───────────────────────────

def load_catalog(path=None):
    p = Path(path) if path else ws() / "catalog.json"
    if not p.exists():
        p = Path(__file__).parent / "catalog.json"  # fallback: cạnh script
    _state["catalog"] = json.loads(p.read_text(encoding="utf-8"))
    return _state["catalog"]


def catalog_models():
    if _state["catalog"] is None:
        load_catalog()
    return _state["catalog"].get("models", [])


def model_entry(model_id):
    for m in catalog_models():
        if m.get("id") == model_id:
            return m
    raise KeyError(f"Không có model '{model_id}' trong catalog")


def model_dirs(m) -> list:
    """Thư mục trong workspace thuộc về model này (tính size / xóa)."""
    return [ws() / r["local_dir"] for r in (m.get("repos") or []) if not r.get("only_files")]


def model_required_files(m) -> list:
    return [ws() / f for f in (m.get("require") or [])]


def dir_size(p: Path) -> int:
    if not p.exists():
        return 0
    total = 0
    for f in p.rglob("*"):
        try:
            if f.is_file():
                total += f.stat().st_size
        except OSError:
            pass
    return total


def cmd_model_status(*, model_id=None, **_):
    out = []
    for m in catalog_models():
        if model_id and m.get("id") != model_id:
            continue
        if m.get("engine") == "edge" or m.get("no_download"):
            out.append({"id": m["id"], "installed": True, "partial": False,
                        "size_bytes": 0, "missing": []})
            continue
        missing = [f for f in model_required_files(m) if not f.exists()]
        size = sum(dir_size(d) for d in model_dirs(m))
        out.append({
            "id": m["id"], "installed": not missing,
            "partial": bool(missing) and size > 0, "size_bytes": size,
            "missing": [str(f.relative_to(ws())) for f in missing],
        })
    return {"models": out}


def _download_model(model_id):
    """Tải lần lượt từng file của từng repo vào local_dir; hủy được, resume được."""
    m = model_entry(model_id)
    cancel = _state["cancel_flags"].setdefault(f"dl:{model_id}", threading.Event())
    cancel.clear()
    repos = m.get("repos") or []
    if not repos:
        return {"installed": True, "size_bytes": 0}

    from huggingface_hub import HfApi, hf_hub_download
    api = HfApi()

    plan, grand_total = [], 0
    for r in repos:
        patterns = r.get("patterns") or ["*"]
        info = api.model_info(r["repo_id"], files_metadata=True)
        names = []
        for s in info.siblings or []:
            n = s.rfilename
            if n.startswith(".") or n.endswith((".md", ".gitattributes", ".png", ".jpg")):
                continue
            if "*" in patterns or any(re.fullmatch(p.replace("*", ".*"), n) for p in patterns):
                names.append(n)
                grand_total += (s.size or 0)
        plan.append((r["repo_id"], ws() / r["local_dir"], names, patterns))
    log(f"tải {model_id}: {sum(len(n) for _, _, n, _ in plan)} file, ~{grand_total/1e6:.0f}MB")
    if grand_total == 0:
        raise RuntimeError("Không thấy file nào khớp patterns trong repo — kiểm tra catalog")

    t0 = time.time()

    def report_progress(finished=False, **extra):
        done = sum(dir_size(d) for _, d, _, _ in plan)
        pct = 100.0 if finished else min(99.0, done * 100.0 / grand_total)
        event("download_progress", model_id=model_id, done_bytes=done,
              total_bytes=grand_total, pct=round(pct, 1),
              speed_bps=done / max(time.time() - t0, 1), **extra)

    for repo_id, local_dir, names, _ in plan:
        local_dir.mkdir(parents=True, exist_ok=True)
        for i, fn in enumerate(names, 1):
            if cancel.is_set():
                raise Cancelled()
            event("download_progress", model_id=model_id, file=fn, repo=repo_id,
                  file_index=i, file_count=len(names))
            for attempt in range(1, 5):
                try:
                    hf_hub_download(repo_id=repo_id, repo_type="model", filename=fn,
                                    local_dir=str(local_dir))
                    break
                except Exception as e:
                    if cancel.is_set():
                        raise Cancelled()
                    log(f"tải {fn} lần {attempt} lỗi: {str(e)[:150]}")
                    if attempt == 4:
                        raise
                    time.sleep(2 * attempt)
            report_progress()
    st = cmd_model_status(model_id=model_id)["models"][0]
    if st["missing"]:
        raise RuntimeError(f"Còn thiếu file sau khi tải: {st['missing'][:5]}")
    report_progress(finished=True)
    return {"installed": True, "size_bytes": st["size_bytes"]}


def cmd_model_download_cancel(*, model_id, **_):
    ev = _state["cancel_flags"].get(f"dl:{model_id}")
    if ev:
        ev.set()
    return {"cancelling": True}


def cmd_model_delete(*, model_id, **_):
    m = model_entry(model_id)
    if _state.get("tts") is not None:
        raise RuntimeError("Đang nạp engine — unload trước khi xóa model")
    removed = []
    for d in model_dirs(m):
        if d.exists():
            shutil.rmtree(d)
            removed.append(str(d))
    return {"removed": removed}


# ─────────────────────────── Parse sách ───────────────────────────

DEFAULT_CHAPTER_RE = (
    r"^\s*(?:Hồi\s+(?:thứ\s+)?(?:[\dIVX]+|nhất|hai|ba|bốn|năm|sáu|bảy|tám|chín|mười)"
    r"|Chương\s+\S+|QUYỂN\s+\S+|Quyển\s+\S+"
    r"|PHẦN\s+\S+|Phần\s+\S+|CHAPTER\s+[IVXLC\d]+|Chapter\s+[\dIVXLC]+"
    r"|Đệ\s.{1,6}chương|第[零一二三四五六七八九十百千万\d]+章"
    r"|Prologue|Epilogue|Preface|Foreword|Introduction"
    r"|Part\s+(?:[IVX]+|\d+|One|Two|Three|Four|Five|Six|Seven|Eight|Nine|Ten|Eleven|Twelve)\b"
    r"|Book\s+(?:[IVX]+|\d+|One|Two|Three|Four|Five|Six|Seven|Eight|Nine|Ten)\b"
    r"|\*\s*(?:Chapter|Prologue)\s+[\dIVX]+\s*\*)"
    r".*$"
)

_VI_CHARS = set("ăâêôơưđĂÂÊÔƠƯĐ")


def detect_language(text: str) -> str:
    """'vi' | 'en' | 'zh' theo tỉ lệ ký tự đặc trưng trong ~8.000 ký tự đầu."""
    sample = text[:8000]
    letters = [c for c in sample if c.isalpha()]
    if not letters:
        return "vi"
    vi = sum(1 for c in letters if c in _VI_CHARS)
    zh = sum(1 for c in letters if "\u4e00" <= c <= "\u9fff")
    n = len(letters)
    if zh / n > 0.3:
        return "zh"
    if vi / n > 0.01:
        return "vi"
    return "en"


def _dedup_lines(lines):
    return [l for i, l in enumerate(lines) if i == 0 or l != lines[i - 1]]


def _html_to_paras(html_bytes):
    from bs4 import BeautifulSoup
    soup = BeautifulSoup(html_bytes, "lxml")
    lines = [l.strip() for l in soup.get_text("\n", strip=True).splitlines() if l.strip()]
    return _dedup_lines(lines)


def _epub_parse(path: Path):
    z = zipfile.ZipFile(path)
    names = set(z.namelist())
    cont = z.read("META-INF/container.xml").decode("utf-8", "ignore")
    opf_path = re.search(r'full-path="([^"]+)"', cont).group(1)
    opf_dir = opf_path.rsplit("/", 1)[0] + "/" if "/" in opf_path else ""
    from bs4 import BeautifulSoup
    opf = BeautifulSoup(z.read(opf_path), "lxml")

    def opf_url(u):
        u = u.split("#")[0]
        return opf_dir + u if not u.startswith("/") else u.lstrip("/")

    t = opf.find("dc:title")
    title = t.get_text(strip=True) if t else path.stem
    c = opf.find("dc:creator")
    author = c.get_text(strip=True) if c else ""

    manifest = {}
    for it in opf.find_all("item"):
        if it.get("id") and it.get("href"):
            manifest[it["id"]] = {"href": opf_url(it["href"]),
                                  "media": it.get("media-type", ""),
                                  "props": it.get("properties", "")}
    spine_ids = [t["idref"] for t in opf.find_all("itemref") if t.get("idref")]

    # TOC: nav.xhtml (EPUB3) rồi toc.ncx (EPUB2) — map file -> tiêu đề
    toc = {}
    nav_item = next((v for v in manifest.values() if "nav" in (v.get("props") or "")), None)
    ncx_item = None
    spine_tag = opf.find("spine")
    if spine_tag and spine_tag.get("toc"):
        ncx_item = manifest.get(spine_tag.get("toc"))
    if nav_item and nav_item["href"] in names:
        nav = BeautifulSoup(z.read(nav_item["href"]), "lxml")
        base = nav_item["href"].rsplit("/", 1)[0] + "/" if "/" in nav_item["href"] else ""
        for a in nav.find_all("a"):
            href = a.get("href")
            if href:
                key = base + href.split("#")[0] if not href.startswith("/") else href.lstrip("/")
                toc.setdefault(key, a.get_text(strip=True))
    elif ncx_item and ncx_item["href"] in names:
        ncx = BeautifulSoup(z.read(ncx_item["href"]), "lxml")
        base = ncx_item["href"].rsplit("/", 1)[0] + "/" if "/" in ncx_item["href"] else ""
        for pt in ncx.find_all("navpoint"):
            s, t2 = pt.find("content"), pt.find("text")
            if s is not None and t2 is not None and s.get("src"):
                src = s["src"]
                key = base + src.split("#")[0] if not src.startswith("/") else src.lstrip("/")
                toc.setdefault(key, t2.get_text(strip=True))

    cover = None
    cover_item = next((v for v in manifest.values() if "cover-image" in (v.get("props") or "")), None)
    if not cover_item:
        meta_cover = opf.find("meta", {"name": "cover"})
        cover_item = manifest.get(meta_cover.get("content")) if meta_cover else None
    if cover_item and cover_item["href"] in names:
        cover = (cover_item["href"], z.read(cover_item["href"]))

    chapters = []
    for sid in spine_ids:
        item = manifest.get(sid)
        if not item or "html" not in item.get("media", ""):
            continue
        href = item["href"]
        if href not in names or "nav" in (item.get("props") or ""):
            continue
        paras = _html_to_paras(z.read(href))
        if not paras:
            continue
        ch_title = toc.get(href, "")
        if not ch_title:
            head = [l for l in paras[:3] if len(l) < 70]
            ch_title = head[0] if head else paras[0][:60]
        chapters.append((ch_title, paras))
    return {"title": title, "author": author, "cover": cover, "chapters": chapters}


def _docx_paras(path: Path):
    from bs4 import BeautifulSoup
    z = zipfile.ZipFile(path)
    doc = BeautifulSoup(z.read("word/document.xml"), "lxml")
    paras = [p.get_text(" ", strip=True) for p in doc.find_all("w:p")]
    return _dedup_lines([p for p in paras if p])


def _txt_paras(path: Path, encoding=None):
    raw = path.read_bytes()
    for enc in ([encoding] if encoding else ["utf-8-sig", "utf-8", "utf-16", "cp1258"]):
        try:
            text = raw.decode(enc)
            break
        except (UnicodeDecodeError, LookupError):
            continue
    else:
        text = raw.decode("utf-8", errors="replace")
    return _dedup_lines([l.strip() for l in text.splitlines() if l.strip()])


def split_chapters(paras, chapter_regex=None, min_chars=200):
    """Chia đoạn văn thành chương theo regex tiêu đề; không khớp thì 1 chương duy nhất."""
    rx = re.compile(chapter_regex or DEFAULT_CHAPTER_RE, re.IGNORECASE)
    chapters, cur_title, cur = [], None, []
    for p in paras:
        if len(p) < 80 and rx.match(p):
            if cur:
                chapters.append((cur_title, cur))
            cur_title, cur = p, []
        else:
            cur.append(p)
    if cur:
        chapters.append((cur_title, cur))
    if len(chapters) < 2:
        return [(None, paras)]
    kept = [(t, ps) for t, ps in chapters if sum(len(x) for x in ps) >= min_chars]
    return kept or chapters


def _write_book(book_id, meta, chapters):
    bdir = ws() / "books" / book_id
    cdir = bdir / "chapters"
    cdir.mkdir(parents=True, exist_ok=True)
    out = []
    for i, (title, paras) in enumerate(chapters):
        fname = f"{i+1:03d}.txt"
        (cdir / fname).write_text("\n\n".join(paras), encoding="utf-8")
        out.append({"index": i + 1, "title": title or f"Phần {i+1}",
                    "file": f"chapters/{fname}",
                    "chars": sum(len(x) for x in paras), "paras": len(paras)})
    full_text = "\n".join("\n".join(ps) for _, ps in chapters[:5])
    manifest = {
        "id": book_id, "title": meta.get("title") or book_id,
        "author": meta.get("author", ""), "source_name": meta.get("source_name", ""),
        "created": time.strftime("%Y-%m-%d %H:%M:%S"), "chapters": out,
        "language": detect_language(full_text),
    }
    if meta.get("cover"):
        ext = (meta["cover"][0].rsplit(".", 1)[-1] or "jpg").lower()
        if not re.fullmatch(r"[a-z0-9]{2,5}", ext):
            ext = "jpg"
        (bdir / f"cover.{ext}").write_bytes(meta["cover"][1])
        manifest["cover"] = f"cover.{ext}"
    (bdir / "book.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=1), encoding="utf-8")
    return manifest


def cmd_parse_book(*, path, book_id, encoding=None, chapter_regex=None, **_):
    p = Path(path)
    if not p.exists():
        raise FileNotFoundError(path)
    suf = p.suffix.lower()
    if suf == ".epub":
        info = _epub_parse(p)
        meta = {"title": info["title"], "author": info["author"],
                "cover": info["cover"], "source_name": p.name}
        chapters = info["chapters"]
    elif suf == ".docx":
        chapters = split_chapters(_docx_paras(p), chapter_regex)
        meta = {"title": p.stem, "source_name": p.name}
    elif suf in (".txt", ".text"):
        chapters = split_chapters(_txt_paras(p, encoding), chapter_regex)
        meta = {"title": p.stem, "source_name": p.name}
    else:
        raise ValueError(f"Worker parse được epub/txt/docx; PDF do app tự parse bằng PDFKit")
    return {"book": _write_book(book_id, meta, chapters)}


def cmd_import_text(*, text, title, book_id, chapter_regex=None, **_):
    paras = [l.strip() for l in text.splitlines() if l.strip()] or [text]
    if len(paras) == 1 and len(paras[0]) > 500:
        paras = [p.strip() for p in re.split(r"\n\s*\n", text) if p.strip()]
    chapters = split_chapters(_dedup_lines(paras), chapter_regex)
    return {"book": _write_book(book_id, {"title": title or "Text dán vào"}, chapters)}


def read_chapter_text(book_id, chapter_file):
    return (ws() / "books" / book_id / chapter_file).read_text(encoding="utf-8")


# ─────────────────────────── Engine ───────────────────────────

def _patch_hf():
    """Trỏ hf_hub_download về thư mục models/ local (như audiobook.py)."""
    import huggingface_hub
    if getattr(huggingface_hub.hf_hub_download, "_storyaudio_patched", False):
        return
    orig = huggingface_hub.hf_hub_download

    def patched(repo_id, filename=None, *a, repo_type=None, subfolder=None, **k):
        d = LOCAL_REPO_MAP.get(repo_id)
        if d:
            p = os.path.join(str(ws()), d, subfolder or "", filename or "")
            if os.path.exists(p):
                return p
        return orig(repo_id, filename, *a, repo_type=repo_type, subfolder=subfolder, **k)

    patched._storyaudio_patched = True
    huggingface_hub.hf_hub_download = patched


def _ensure_engine_installed(model_id):
    st = cmd_model_status(model_id=model_id)["models"][0]
    if not st["installed"]:
        raise ModelMissingError(model_id, st["missing"])


def rss_mb():
    import resource
    return resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024 / 1024


def cmd_engine_load(*, engine, mode=None, threads=2, **_):
    if engine == "edge":
        import edge_tts  # noqa: F401
        _state["engine_kind"], _state["mode"], _state["tts"] = "edge", None, None
        _state["custom_voice_names"] = set()
        _state["kokoro_g2p"] = None
        return {"engine": "edge", "mode": None, "sample_rate": 24000}
    if engine == "kokoro":
        return _kokoro_engine_load()
    if _state["engine_kind"] == "vieneu" and _state["tts"] is not None and _state["mode"] == mode:
        return {"engine": "vieneu", "mode": mode, "sample_rate": _state["tts"].sample_rate}
    _ensure_engine_installed("vieneu-nano" if mode == "v3nano" else "vieneu-turbo")
    _patch_hf()
    from vieneu import Vieneu
    t0 = time.time()
    if mode == "v3nano":
        tts = Vieneu(mode="v3nano", onnx_dir=str(ws() / "models/vieneu-nano"),
                     threads=int(threads))
    else:
        tts = Vieneu(mode="v3turbo",
                     backbone_repo=str(ws() / "models/vieneu-backbone"),
                     onnx_dir=str(ws() / "models/vieneu-backbone/onnx_update"),
                     threads=int(threads))
    _state["tts"], _state["engine_kind"], _state["mode"] = tts, "vieneu", mode
    _state["kokoro_g2p"] = None
    _load_custom_voice_names()
    log(f"nạp engine {mode} xong sau {time.time()-t0:.0f}s, RAM {rss_mb():.0f}MB")
    return {"engine": "vieneu", "mode": mode, "sample_rate": tts.sample_rate,
            "load_seconds": round(time.time() - t0, 1)}


# ─────────────────────────── Engine Kokoro (sách tiếng Anh, offline) ───────────────────────────

KOKORO_MODEL_ID = "kokoro-en"
KOKORO_SAMPLE_RATE = 24000
# 3 ký tự đầu tên giọng Kokoro → (giới tính,accent, locale) — chỉ giữ giọng tiếng Anh
_KOKORO_EN_PREFIX = {
    "af_": ("nữ", "Mỹ", "en-US"),
    "am_": ("nam", "Mỹ", "en-US"),
    "bf_": ("nữ", "Anh", "en-GB"),
    "bm_": ("nam", "Anh", "en-GB"),
}


def _kokoro_engine_load():
    _ensure_engine_installed(KOKORO_MODEL_ID)
    if _state["engine_kind"] == "kokoro" and _state["tts"] is not None:
        return {"engine": "kokoro", "mode": None, "sample_rate": KOKORO_SAMPLE_RATE}
    try:
        from kokoro_onnx import Kokoro
    except ImportError as e:
        raise RuntimeError(
            f"Thiếu gói kokoro-onnx trong venv ({e}) — vào Cài đặt → Nâng cao, "
            "chạy lại Cài đặt runtime rồi khởi động lại worker.")
    t0 = time.time()
    model = ws() / "models/kokoro/model.onnx"
    voices = ws() / "models/kokoro/voices.bin"
    kokoro = Kokoro(str(model), str(voices))
    _state["tts"], _state["engine_kind"], _state["mode"] = kokoro, "kokoro", None
    _state["custom_voice_names"] = set()
    _state["kokoro_g2p"] = _kokoro_make_g2p()
    log(f"nạp engine kokoro xong sau {time.time()-t0:.0f}s, RAM {rss_mb():.0f}MB")
    return {"engine": "kokoro", "mode": None, "sample_rate": KOKORO_SAMPLE_RATE,
            "load_seconds": round(time.time() - t0, 1)}


def _kokoro_make_g2p():
    """misaki G2P đúng phoneme Kokoro được train (tốt hơn espeak cho số/tên riêng).
    Lần đầu có thể tải spacy model en_core_web_sm (~13MB) — setup_runtime đã prefetch."""
    try:
        from misaki import en, espeak
        t0 = time.time()
        g2p = en.G2P(trf=False, british=False, fallback=espeak.EspeakFallback(british=False))
        log(f"misaki G2P sẵn sàng sau {time.time()-t0:.0f}s")
        return g2p
    except Exception as e:
        log(f"misaki không khả dụng ({type(e).__name__}: {str(e)[:120]}) — "
            "dùng phonemize espeak built-in của kokoro-onnx")
        return None


def _kokoro_synth(text, voice, speed=1.0):
    """Trả (samples float32, sample_rate). create() tự chia batch ≤510 phoneme
    theo câu/mệnh đề + trim + chèn pause; speed của model giới hạn 0.5–2.0."""
    kokoro = _state["tts"]
    speed = min(max(float(speed or 1.0), 0.5), 2.0)
    g2p = _state.get("kokoro_g2p")
    if g2p is not None:
        try:
            phonemes, _ = g2p(text)
            return kokoro.create(phonemes, voice, is_phonemes=True, speed=speed)
        except Exception as e:
            log(f"misaki G2P lỗi ({type(e).__name__}: {str(e)[:120]}) — chuyển espeak")
    return kokoro.create(text, voice, speed=speed, lang="en-us")


def cmd_engine_unload(**_):
    _state["tts"] = None
    _state["engine_kind"] = _state["mode"] = None
    _state["custom_voice_names"] = set()
    _state["kokoro_g2p"] = None
    gc.collect()
    return {"unloaded": True}


def _tts():
    if _state["tts"] is None:
        raise RuntimeError("Engine chưa nạp — gọi engine_load trước")
    return _state["tts"]


def cmd_list_voices(**_):
    if _state["engine_kind"] == "edge":
        import asyncio
        import edge_tts

        async def _list():
            vs = await edge_tts.list_voices()
            out = []
            for v in vs:
                loc, short = v.get("Locale", ""), v.get("ShortName", "")
                # ưu tiên gọn: tiếng Việt + mọi biến thể tiếng Anh
                if loc.startswith("vi-") or loc.startswith("en-"):
                    out.append({"id": short,
                                "label": f"{short} — {v.get('Gender', '')}",
                                "custom": False, "engine": "edge",
                                "locale": loc,
                                "lang": "vi" if loc.startswith("vi-") else "en"})
            out.sort(key=lambda x: (x["lang"] != "vi", x["id"]))
            return out
        return {"voices": asyncio.run(_list())}
    if _state["engine_kind"] == "kokoro":
        out = []
        for name in _state["tts"].get_voices():
            meta = _KOKORO_EN_PREFIX.get(name[:3])
            if not meta:            # giọng Nhật/Trung/Pháp… — ngoài phạm vi app
                continue
            gender, accent, locale = meta
            out.append({"id": name, "label": f"{name[3:].capitalize()} — {gender} {accent}",
                        "custom": False, "engine": "kokoro",
                        "locale": locale, "lang": "en"})
        out.sort(key=lambda x: (x["locale"] != "en-US", x["id"]))   # giọng Mỹ lên trước
        return {"voices": out}
    voices, seen = [], set()
    custom_names = _state.get("custom_voice_names") or set()
    for label, vid in _tts().list_preset_voices():
        voices.append({"id": vid, "label": label,
                       "custom": vid in custom_names, "engine": "vieneu"})
        seen.add(vid)
    for name in (_tts()._preset_voices or {}):
        if name not in seen:
            voices.append({"id": name, "label": name, "custom": True, "engine": "vieneu"})
    return {"voices": voices}


# ─────────────────────────── Giọng clone ───────────────────────────
# Giọng clone sau khi enroll nằm chung _preset_voices với giọng có sẵn của engine
# → đánh dấu tên clone trong file workspace để list_voices gắn cờ custom đúng
# (qua các lần chạy) và UI hiện ở mục "Giọng đã clone".

CUSTOM_VOICES_FILE = ".custom_voices.json"


def _require_vieneu(feature: str):
    """Chức năng chỉ có trên engine VieNeu — Edge/Kokoro không hỗ trợ, báo lỗi rõ ràng."""
    if _state["engine_kind"] is None:
        raise RuntimeError("Engine chưa nạp — nạp engine VieNeu trước khi clone giọng")
    if _state["engine_kind"] != "vieneu":
        raise RuntimeError(
            f"Engine hiện tại ({_state['engine_kind']}) không hỗ trợ {feature} — "
            "chỉ dùng được với engine VieNeu (Nano/Turbo). Chuyển engine trong Cài đặt.")


def _custom_voices_path() -> Path:
    return ws() / CUSTOM_VOICES_FILE


def _read_custom_voices_doc() -> dict:
    try:
        return json.loads(_custom_voices_path().read_text(encoding="utf-8"))
    except Exception:
        return {}


def _write_custom_voices_doc(doc: dict):
    _custom_voices_path().write_text(
        json.dumps(doc, ensure_ascii=False, indent=1), encoding="utf-8")


def _mark_custom_voice(name: str):
    if name in _state["custom_voice_names"]:
        return
    _state["custom_voice_names"].add(name)
    doc = _read_custom_voices_doc()
    doc[_state["mode"]] = sorted(_state["custom_voice_names"])
    _write_custom_voices_doc(doc)


def _unmark_custom_voice(name: str):
    if name not in _state["custom_voice_names"]:
        return
    _state["custom_voice_names"].discard(name)
    doc = _read_custom_voices_doc()
    doc[_state["mode"]] = sorted(_state["custom_voice_names"])
    _write_custom_voices_doc(doc)


def _load_custom_voice_names():
    _state["custom_voice_names"] = set(
        _read_custom_voices_doc().get(_state["mode"]) or [])


def cmd_clone_voice(*, name, ref_path, denoise=True, **_):
    _require_vieneu("clone giọng")
    if not Path(ref_path).exists():
        raise FileNotFoundError(ref_path)
    t0 = time.time()
    _tts().add_voice(name, ref_path, denoise=bool(denoise), save=True)
    _mark_custom_voice(name)
    return {"name": name, "elapsed": round(time.time() - t0, 1)}


def cmd_delete_voice(*, name, **_):
    _require_vieneu("xóa giọng clone")
    _tts().remove_voice(name, save=True)
    _unmark_custom_voice(name)
    return {"deleted": name}


def cmd_export_voices(*, path, **_):
    _require_vieneu("xuất backup giọng")
    return {"path": _tts().save_voices(path)}


def cmd_import_voices(*, path, **_):
    _require_vieneu("nhập backup giọng")
    import numpy as np
    from vieneu_utils.core_utils import strip_encoder_pad_frame
    tts = _tts()
    data = json.loads(Path(path).read_text(encoding="utf-8"))
    added = 0
    for name, v in (data.get("presets") or {}).items():
        emb, codes = v.get("speaker_emb"), v.get("codes")
        if emb is None:
            continue
        tts._preset_voices[name] = {
            "description": v.get("description", ""), "gender": v.get("gender", ""),
            "style": v.get("style", tts.default_style), "featured": None, "aliases": [],
            "speaker_emb": np.asarray(emb, dtype=np.float32),
            "codes": (strip_encoder_pad_frame(np.asarray(codes, dtype=np.int64))
                      if codes is not None else None),
        }
        _mark_custom_voice(name)
        added += 1
    tts.save_voices()
    return {"added": added}


def _infer_kwargs(params):
    keys = ("temperature", "top_k", "top_p", "repetition_penalty", "steps", "cfg", "speed")
    return {k: params[k] for k in keys if k in params}


def cmd_preview(*, voice, text, out_path=None, params=None, **_):
    params = params or {}
    if _state["engine_kind"] == "kokoro":
        import soundfile as sf
        out = Path(out_path) if out_path else ws() / "build/preview" / f"preview-{int(time.time())}.wav"
        out.parent.mkdir(parents=True, exist_ok=True)
        samples, sr = _kokoro_synth(text, voice, params.get("speed", 1.0))
        sf.write(str(out), samples, sr)
        return {"path": str(out), "duration": round(len(samples) / sr, 1),
                "sample_rate": sr}
    if _state["engine_kind"] == "edge":
        import asyncio
        import edge_tts
        out = Path(out_path) if out_path else ws() / "build/preview" / f"preview-{int(time.time())}.mp3"
        out.parent.mkdir(parents=True, exist_ok=True)
        rate = f"{int(params.get('rate_pct', 0) or 0):+d}%"

        async def _gen():
            await edge_tts.Communicate(text, voice, rate=rate).save(str(out))
        asyncio.run(_gen())
        return {"path": str(out), "duration": None, "sample_rate": 24000}
    tts = _tts()
    out = Path(out_path) if out_path else ws() / "build/preview" / f"preview-{int(time.time())}.wav"
    out.parent.mkdir(parents=True, exist_ok=True)
    wav = tts.infer(text, voice=voice, **_infer_kwargs(params))
    tts.save(wav, str(out))
    return {"path": str(out), "duration": round(len(wav) / tts.sample_rate, 1),
            "sample_rate": tts.sample_rate}


# ─────────────────────────── Render ───────────────────────────

def apply_rules(text, rules):
    for r in rules or []:
        find, rep = r.get("find", ""), r.get("replace", "")
        if not find:
            continue
        if r.get("regex"):
            try:
                text = re.sub(find, rep, text)
            except re.error:
                pass
        else:
            text = text.replace(find, rep)
    return text


def split_parts(paras, limit, ramp=None):
    """Chia đoạn văn thành các part (chỉ cắt ở ranh giới đoạn văn).
    ramp = list giới hạn ký tự cho các part đầu — part nhỏ sớm hơn để nghe dần
    không phải chờ nguyên part lớn."""
    limits = (list(ramp) if ramp else []) + [limit]
    parts, cur, cur_len = [], [], 0
    for p in paras:
        cap = limits[len(parts)] if len(parts) < len(limits) else limit
        if cur and cur_len + len(p) > cap:
            parts.append("\n".join(cur))
            cur, cur_len = [], 0
        cur.append(p)
        cur_len += len(p)
    if cur:
        parts.append("\n".join(cur))
    return parts


def _parts_json_reset_if_changed(build_dir, part_chars, ramp, gap):
    """parts.json của lần dựng trước mà bố cục khác (đổi part_chars/ramp/gap)
    → xóa build dir dựng lại, tránh resume lệch part."""
    try:
        old = json.loads((build_dir / "parts.json").read_text(encoding="utf-8"))
    except Exception:
        return
    if (old.get("part_chars") != part_chars or old.get("ramp") != (ramp or [])
            or abs(float(old.get("gap_s", -1)) - gap) > 1e-9):
        shutil.rmtree(build_dir, ignore_errors=True)
        build_dir.mkdir(parents=True, exist_ok=True)   # tạo lại để render tiếp


def _parts_json_write(build_dir, doc):
    """Ghi manifest part (app đọc để nghe dần) — atomic để app không đọc dở."""
    tmp = build_dir / "parts.json.tmp"
    try:
        tmp.write_text(json.dumps(doc, ensure_ascii=False), encoding="utf-8")
        tmp.replace(build_dir / "parts.json")
    except OSError:
        pass


def _parts_manifest(part_chars, ramp, gap, total):
    return {"version": 1, "parts_total": total, "gap_s": gap,
            "part_chars": part_chars, "ramp": ramp or [], "parts": []}


def _run(cmd):
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"lệnh {cmd[0]} lỗi: {r.stderr[:200]}")


def encode_audio(wav_path: Path, out_noext: Path, fmt: str, title="", artist=""):
    """Ghi đè đuôi theo fmt — nối thẳng vào tên vì tên file có thể chứa dấu chấm."""
    fmt = fmt.lower()
    ext = {"mp3": ".mp3", "wav": ".wav"}.get(fmt, ".m4a")
    out = out_noext.parent / (out_noext.name + ext)
    if fmt == "wav":
        shutil.copyfile(wav_path, out)
        return out
    if fmt == "mp3":
        _run(["lame", "--quiet", "-V", "2", "--tt", title, "--ta", artist,
              str(wav_path), str(out)])
        return out
    _run(["afconvert", "-f", "m4af", "-d", "aac", str(wav_path), str(out)])
    return out


def _job_text(job):
    text = job.get("text") or read_chapter_text(job["book_id"], job["chapter_file"])
    return apply_rules(text, job.get("rules"))


def _render_vieneu(job, cancel):
    tts = _tts()
    paras = [p for p in (t.strip() for t in _job_text(job).split("\n")) if p]
    part_chars = int(job.get("part_chars", 4500))
    ramp = [int(x) for x in (job.get("part_ramp") or [])]
    gap = float(job.get("silence_s", 0.6))
    parts = split_parts(paras, part_chars, ramp)
    build_dir = Path(job.get("build_dir") or (ws() / "build" / job["slug"]))
    build_dir.mkdir(parents=True, exist_ok=True)
    _parts_json_reset_if_changed(build_dir, part_chars, ramp, gap)
    manifest = _parts_manifest(part_chars, ramp, gap, len(parts))
    _parts_json_write(build_dir, manifest)
    infer_kw = _infer_kwargs(job.get("params") or {})
    voice, sr = job.get("voice"), tts.sample_rate
    t_start, total_audio = time.time(), 0.0

    import soundfile as sf
    for i, part in enumerate(parts, 1):
        if cancel.is_set():
            raise Cancelled()
        wav_path = build_dir / f"part-{i:03d}.wav"
        if wav_path.exists() and wav_path.stat().st_size > 1000:
            dur = sf.info(wav_path).duration
            total_audio += dur
            manifest["parts"].append({"file": wav_path.name, "chars": len(part),
                                      "audio_sec": round(dur, 3)})
            _parts_json_write(build_dir, manifest)
            event("render_progress", job_id=job["job_id"], part=i, parts=len(parts),
                  skipped=True, audio_sec=round(total_audio, 1),
                  part_audio_sec=round(dur, 1), rss_mb=rss_mb())
            continue
        ok = False
        for attempt in range(1, 4):
            if cancel.is_set():
                raise Cancelled()
            try:
                t0 = time.time()
                wav = tts.infer(part, voice=voice, **infer_kw)
                tts.save(wav, str(wav_path))
                dur = len(wav) / sr
                total_audio += dur
                manifest["parts"].append({"file": wav_path.name, "chars": len(part),
                                          "audio_sec": round(dur, 3)})
                _parts_json_write(build_dir, manifest)
                event("render_progress", job_id=job["job_id"], part=i, parts=len(parts),
                      chars=len(part), audio_sec=round(total_audio, 1),
                      part_audio_sec=round(dur, 1),
                      part_seconds=round(time.time() - t0, 1), rss_mb=rss_mb())
                del wav
                gc.collect()
                ok = True
                break
            except Exception as e:
                log(f"job {job['job_id']} đoạn {i} lần {attempt} lỗi: "
                    f"{type(e).__name__}: {str(e)[:150]}")
                time.sleep(3)
        if not ok:
            raise RuntimeError(f"Đoạn {i}/{len(parts)} thất bại sau 3 lần thử")

    # gộp streaming — RAM đỉnh chỉ ~1 đoạn
    import numpy as np
    event("render_stage", job_id=job["job_id"], stage="concat")
    silence = np.zeros(int(sr * gap), dtype="float32")
    final_wav = build_dir / f"{job['slug']}.wav"
    with sf.SoundFile(final_wav, "w", samplerate=sr, channels=1, subtype="FLOAT") as fout:
        for i in range(1, len(parts) + 1):
            a, _ = sf.read(build_dir / f"part-{i:03d}.wav", dtype="float32")
            fout.write(a)
            fout.write(silence)
            del a
    out_noext = Path(job["out_path"])
    out_noext.parent.mkdir(parents=True, exist_ok=True)
    event("render_stage", job_id=job["job_id"], stage="encode")
    final = encode_audio(final_wav, out_noext, job.get("format", "m4a"),
                         title=job.get("title", ""), artist=job.get("artist", ""))
    if job.get("cleanup_parts"):
        shutil.rmtree(build_dir, ignore_errors=True)
    return {"file": str(final), "duration_sec": round(total_audio, 1),
            "size_bytes": final.stat().st_size,
            "elapsed_sec": round(time.time() - t_start, 1), "parts": len(parts)}


def _render_edge(job, cancel):
    import asyncio
    import edge_tts
    paras = [p for p in (t.strip() for t in _job_text(job).split("\n")) if p]
    part_chars = min(int(job.get("part_chars", 4500)), 3000)
    ramp = [min(int(x), 3000) for x in (job.get("part_ramp") or [])]
    gap = float(job.get("silence_s", 0.6))
    parts = split_parts(paras, part_chars, ramp)
    build_dir = Path(job.get("build_dir") or (ws() / "build" / job["slug"]))
    build_dir.mkdir(parents=True, exist_ok=True)
    _parts_json_reset_if_changed(build_dir, part_chars, ramp, gap)
    manifest = _parts_manifest(part_chars, ramp, gap, len(parts))
    _parts_json_write(build_dir, manifest)
    voice = job["voice"]
    rate = f"{int(job.get('rate_pct', 0) or 0):+d}%"
    t_start = time.time()

    for i, part in enumerate(parts, 1):
        if cancel.is_set():
            raise Cancelled()
        mp3_path = build_dir / f"part-{i:03d}.mp3"
        if not (mp3_path.exists() and mp3_path.stat().st_size > 1000):
            for attempt in range(1, 4):
                try:
                    asyncio.run(edge_tts.Communicate(part, voice, rate=rate)
                                .save(str(mp3_path)))
                    break
                except Exception as e:
                    log(f"edge job {job['job_id']} đoạn {i} lần {attempt}: {str(e)[:150]}")
                    time.sleep(2 * attempt)
            else:
                raise RuntimeError(f"Edge đoạn {i} thất bại sau 3 lần")
        # mp3 chưa decode nên chưa biết thời lượng — app tự đo khi phát
        manifest["parts"].append({"file": mp3_path.name, "chars": len(part),
                                  "audio_sec": None})
        _parts_json_write(build_dir, manifest)
        event("render_progress", job_id=job["job_id"], part=i, parts=len(parts),
              chars=len(part), rss_mb=rss_mb())

    # decode mp3 -> wav, gộp streaming, encode lại định dạng đích
    import numpy as np
    import soundfile as sf
    event("render_stage", job_id=job["job_id"], stage="concat")
    final_wav = build_dir / f"{job['slug']}.wav"
    with sf.SoundFile(final_wav, "w", samplerate=24000, channels=1, subtype="FLOAT") as fout:
        for i in range(1, len(parts) + 1):
            w = build_dir / f"part-{i:03d}.wav"
            if not w.exists():
                _run(["lame", "--quiet", "--decode",
                      str(build_dir / f"part-{i:03d}.mp3"), str(w)])
            a, _ = sf.read(w, dtype="float32")
            fout.write(a)
            fout.write(np.zeros(int(24000 * gap), dtype="float32"))
            del a
    out_noext = Path(job["out_path"])
    out_noext.parent.mkdir(parents=True, exist_ok=True)
    event("render_stage", job_id=job["job_id"], stage="encode")
    final = encode_audio(final_wav, out_noext, job.get("format", "m4a"),
                         title=job.get("title", ""), artist=job.get("artist", ""))
    if job.get("cleanup_parts"):
        shutil.rmtree(build_dir, ignore_errors=True)
    return {"file": str(final), "duration_sec": None,
            "size_bytes": final.stat().st_size,
            "elapsed_sec": round(time.time() - t_start, 1), "parts": len(parts)}


def _render_kokoro(job, cancel):
    paras = [p for p in (t.strip() for t in _job_text(job).split("\n")) if p]
    part_chars = min(int(job.get("part_chars", 4500)), 3000)
    ramp = [min(int(x), 3000) for x in (job.get("part_ramp") or [])]
    gap = float(job.get("silence_s", 0.6))
    parts = split_parts(paras, part_chars, ramp)
    build_dir = Path(job.get("build_dir") or (ws() / "build" / job["slug"]))
    build_dir.mkdir(parents=True, exist_ok=True)
    _parts_json_reset_if_changed(build_dir, part_chars, ramp, gap)
    manifest = _parts_manifest(part_chars, ramp, gap, len(parts))
    _parts_json_write(build_dir, manifest)
    voice = job["voice"]
    speed = (job.get("params") or {}).get("speed", 1.0)
    sr = KOKORO_SAMPLE_RATE
    t_start, total_audio = time.time(), 0.0

    import soundfile as sf
    for i, part in enumerate(parts, 1):
        if cancel.is_set():
            raise Cancelled()
        wav_path = build_dir / f"part-{i:03d}.wav"
        if wav_path.exists() and wav_path.stat().st_size > 1000:
            dur = sf.info(wav_path).duration
            total_audio += dur
            manifest["parts"].append({"file": wav_path.name, "chars": len(part),
                                      "audio_sec": round(dur, 3)})
            _parts_json_write(build_dir, manifest)
            event("render_progress", job_id=job["job_id"], part=i, parts=len(parts),
                  skipped=True, audio_sec=round(total_audio, 1),
                  part_audio_sec=round(dur, 1), rss_mb=rss_mb())
            continue
        ok = False
        for attempt in range(1, 4):
            if cancel.is_set():
                raise Cancelled()
            try:
                t0 = time.time()
                samples, _ = _kokoro_synth(part, voice, speed)
                sf.write(str(wav_path), samples, sr)
                dur = len(samples) / sr
                total_audio += dur
                manifest["parts"].append({"file": wav_path.name, "chars": len(part),
                                          "audio_sec": round(dur, 3)})
                _parts_json_write(build_dir, manifest)
                event("render_progress", job_id=job["job_id"], part=i, parts=len(parts),
                      chars=len(part), audio_sec=round(total_audio, 1),
                      part_audio_sec=round(dur, 1),
                      part_seconds=round(time.time() - t0, 1), rss_mb=rss_mb())
                del samples
                gc.collect()
                ok = True
                break
            except Exception as e:
                log(f"kokoro job {job['job_id']} đoạn {i} lần {attempt} lỗi: "
                    f"{type(e).__name__}: {str(e)[:150]}")
                time.sleep(3)
        if not ok:
            raise RuntimeError(f"Đoạn {i}/{len(parts)} thất bại sau 3 lần thử")

    # gộp streaming — RAM đỉnh chỉ ~1 đoạn (giống _render_vieneu)
    import numpy as np
    event("render_stage", job_id=job["job_id"], stage="concat")
    silence = np.zeros(int(sr * gap), dtype="float32")
    final_wav = build_dir / f"{job['slug']}.wav"
    with sf.SoundFile(final_wav, "w", samplerate=sr, channels=1, subtype="FLOAT") as fout:
        for i in range(1, len(parts) + 1):
            a, _ = sf.read(build_dir / f"part-{i:03d}.wav", dtype="float32")
            fout.write(a)
            fout.write(silence)
            del a
    out_noext = Path(job["out_path"])
    out_noext.parent.mkdir(parents=True, exist_ok=True)
    event("render_stage", job_id=job["job_id"], stage="encode")
    final = encode_audio(final_wav, out_noext, job.get("format", "m4a"),
                         title=job.get("title", ""), artist=job.get("artist", ""))
    if job.get("cleanup_parts"):
        shutil.rmtree(build_dir, ignore_errors=True)
    return {"file": str(final), "duration_sec": round(total_audio, 1),
            "size_bytes": final.stat().st_size,
            "elapsed_sec": round(time.time() - t_start, 1), "parts": len(parts)}


def cmd_render(*, job, **_):
    cancel = _state["cancel_flags"].setdefault(f"job:{job['job_id']}", threading.Event())
    cancel.clear()
    if _state["engine_kind"] == "edge" or job.get("engine") == "edge":
        return _render_edge(job, cancel)
    if _state["engine_kind"] == "kokoro" or job.get("engine") == "kokoro":
        return _render_kokoro(job, cancel)
    return _render_vieneu(job, cancel)


# ─────────────────────────── Lệnh tiện ích ───────────────────────────

def _try_import(mod):
    try:
        __import__(mod)
        return True
    except Exception:
        return False


def _mem_total_gb():
    try:
        out = subprocess.run(["sysctl", "-n", "hw.memsize"], capture_output=True, text=True)
        return round(int(out.stdout.strip()) / 1024 ** 3, 1)
    except Exception:
        return 0


def cmd_hello(**_):
    return {"python": sys.version.split()[0], "executable": sys.executable,
            "pid": os.getpid(),
            "has_vieneu": _try_import("vieneu"), "has_edge": _try_import("edge_tts"),
            "has_kokoro": _try_import("kokoro_onnx"),
            "engine_kind": _state["engine_kind"], "mode": _state["mode"]}


def cmd_init(*, workspace, catalog_path=None, **_):
    _state["workspace"] = str(Path(workspace).resolve())
    Path(_state["workspace"], "books").mkdir(parents=True, exist_ok=True)
    Path(_state["workspace"], "build").mkdir(parents=True, exist_ok=True)
    load_catalog(catalog_path)
    return {"workspace": _state["workspace"], "models": len(catalog_models())}


def cmd_cancel(*, job_id=None, model_id=None, **_):
    cancelled = []
    for key, val in (("job", job_id), ("dl", model_id)):
        if val:
            ev = _state["cancel_flags"].get(f"{key}:{val}")
            if ev:
                ev.set()
                cancelled.append(val)
    return {"cancelled": cancelled}


def _dl_wrap(*, model_id, **_):
    m = model_entry(model_id)
    if m.get("engine") == "edge" or m.get("no_download"):
        return {"installed": True, "size_bytes": 0}
    return _download_model(model_id)


HANDLERS = {
    "hello": cmd_hello,
    "sysinfo": lambda **kw: {"cpu_count": os.cpu_count(), "mem_total_gb": _mem_total_gb()},
    "init": cmd_init,
    "model_catalog": lambda **kw: {"models": catalog_models()},
    "model_status": cmd_model_status,
    "model_download": _dl_wrap,
    "model_download_cancel": cmd_model_download_cancel,
    "model_delete": cmd_model_delete,
    "parse_book": cmd_parse_book,
    "import_text": cmd_import_text,
    "engine_load": cmd_engine_load,
    "engine_unload": cmd_engine_unload,
    "list_voices": cmd_list_voices,
    "clone_voice": cmd_clone_voice,
    "delete_voice": cmd_delete_voice,
    "export_voices": cmd_export_voices,
    "import_voices": cmd_import_voices,
    "preview": cmd_preview,
    "render": cmd_render,
    "cancel": cmd_cancel,
    "ping": lambda **kw: {"pong": True},
}

# Lệnh chạy tuần tự trong executor (lâu / phụ thuộc state engine → phải giữ thứ tự FIFO)
QUEUED = {"model_download", "model_delete", "engine_load", "engine_unload",
          "parse_book", "import_text", "render",
          "list_voices", "preview", "clone_voice", "delete_voice",
          "export_voices", "import_voices"}


def handle_request(req):
    """Chạy 1 lệnh và trả lời. Được gọi từ main thread (lệnh tức thì) hoặc executor."""
    req_id, cmd = req.get("id"), req.get("cmd")
    handler = HANDLERS.get(cmd)
    if handler is None:
        reply(req_id, ok=False, error=f"không biết lệnh '{cmd}'")
        return
    kwargs = {k: v for k, v in req.items() if k not in ("id", "cmd")}
    try:
        result = handler(**kwargs)
        reply(req_id, **result)
    except Cancelled:
        reply(req_id, ok=False, error="cancelled")
    except ModelMissingError as e:
        reply(req_id, ok=False, error=f"model_missing:{e.model_id}",
              model_missing=e.model_id, missing=e.missing[:10])
    except FileNotFoundError as e:
        reply(req_id, ok=False, error=f"Không tìm thấy: {e}")
    except Exception as e:
        log(f"lệnh {cmd} lỗi: {type(e).__name__}: {str(e)[:300]}")
        reply(req_id, ok=False, error=f"{type(e).__name__}: {str(e)[:300]}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--workspace", default=None)
    ap.add_argument("--catalog", default=None)
    ap.add_argument("--hf-endpoint", default=None,
                    help="mirror HF, vd https://hf-mirror.com (đặt trước khi import hub)")
    args = ap.parse_args()
    if args.hf_endpoint:
        os.environ["HF_ENDPOINT"] = args.hf_endpoint
    if args.workspace:
        try:
            _state["workspace"] = str(Path(args.workspace).resolve())
        except Exception:
            pass
    if args.catalog:
        try:
            load_catalog(args.catalog)
        except Exception as e:
            log(f"không đọc được catalog {args.catalog}: {e}")

    job_q = queue.Queue()

    def executor():
        while True:
            req = job_q.get()
            try:
                if req is None:
                    break
                try:
                    handle_request(req)
                except Exception as e:  # không bao giờ để executor chết
                    log(f"executor lỗi ngoài dự kiến: {e}")
            finally:
                job_q.task_done()

    threading.Thread(target=executor, daemon=True).start()
    log(f"worker khởi động pid={os.getpid()} py={sys.version.split()[0]}")

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError as e:
            log(f"dòng vào không phải JSON ({e}): {line[:80]}")
            continue
        cmd = req.get("cmd")
        if cmd == "shutdown":
            reply(req.get("id"), bye=True)
            break
        if cmd in QUEUED:
            job_q.put(req)
        else:
            handle_request(req)
    # stdin đóng: chờ hết hàng đợi (job đang chạy làm xong phần việc của nó rồi thoát)
    job_q.put(None)
    job_q.join()
    log("worker thoát")


if __name__ == "__main__":
    main()
