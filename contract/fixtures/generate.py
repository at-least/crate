#!/usr/bin/env python3
"""
Mu contract fixtures 產生器（兼參考實作）

- 用 ffmpeg 產生真實音訊檔（髒檔案例手工構造位元組）
- 內含 Python 參考掃描器（依 contract/model.md 規格）
- 每案例輸出 cases/<name>/lib/... + expected.json（byte-canonical）

重跑：python3 generate.py   （需 ffmpeg；產物已 commit，平時不需要重跑）
"""
import json, os, shutil, struct, subprocess, sys, zlib
from pathlib import Path

HERE = Path(__file__).parent
CASES = HERE / "cases"

def _png_1x1() -> bytes:
    def chunk(t, d):
        return (struct.pack(">I", len(d)) + t + d +
                struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF))
    ihdr = struct.pack(">IIBBBBB", 1, 1, 8, 6, 0, 0, 0)
    idat = zlib.compress(b"\x00\x00\x00\x00\xff", 9)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) +
            chunk(b"IDAT", idat) + chunk(b"IEND", b""))

PNG1x1 = _png_1x1()

# ---------------------------------------------------------------- audio makers

_AUDIO_CACHE: dict[str, bytes] = {}

def _ffmpeg(args: list[str], ext: str) -> bytes:
    import tempfile
    with tempfile.TemporaryDirectory() as td:
        out = Path(td) / f"out.{ext}"
        cmd = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
               "-f", "lavfi", "-i", "anullsrc=r=44100:cl=mono"] + args + [str(out)]
        r = subprocess.run(cmd, capture_output=True)
        if r.returncode != 0:
            raise RuntimeError(f"ffmpeg failed: {cmd}\n{r.stderr.decode()}")
        return out.read_bytes()

def audio_bytes(fmt: str, meta: dict[str, str] | None = None) -> bytes:
    key = fmt + json.dumps(meta or {}, sort_keys=True)
    if key in _AUDIO_CACHE:
        return _AUDIO_CACHE[key]
    meta = meta or {}
    common = ["-t", "0.3"]
    if fmt == "flac":
        args = common + ["-c:a", "flac"]
        if not meta: args += ["-map_metadata", "-1"]
    elif fmt == "mp3":
        args = common + ["-c:a", "libmp3lame", "-b:a", "64k", "-write_id3v1", "0"]
        if meta: args += ["-id3v2_version", "3"]
        else:    args += ["-map_metadata", "-1"]
    elif fmt == "mp3_utf8_tags":
        fmt = "mp3"
        args = common + ["-c:a", "libmp3lame", "-b:a", "64k",
                         "-write_id3v1", "0", "-id3v2_version", "4"]
    elif fmt == "m4a":
        args = common + ["-c:a", "aac", "-b:a", "64k"]
    elif fmt == "opus":
        args = common + ["-c:a", "libopus", "-b:a", "64k"]
    elif fmt == "ogg":
        args = common + ["-c:a", "libvorbis"]
    elif fmt == "wav":
        args = common + ["-c:a", "pcm_s16le", "-map_metadata", "-1"]
    else:
        raise ValueError(fmt)
    for k, v in meta.items():
        args += ["-metadata", f"{k}={v}"]
    data = _ffmpeg(args, fmt)
    _AUDIO_CACHE[key] = data
    return data

# ------------------------------------------------------------ hand-crafted ID3

def _syncsafe(n: int) -> bytes:
    return bytes([(n >> 21) & 0x7F, (n >> 14) & 0x7F, (n >> 7) & 0x7F, n & 0x7F])

def _id3v23_frame(fid: str, payload: bytes) -> bytes:
    return fid.encode() + struct.pack(">I", len(payload)) + b"\x00\x00" + payload

def _text_frame(fid: str, enc: int, text_bytes: bytes) -> bytes:
    return _id3v23_frame(fid, bytes([enc]) + text_bytes + b"\x00")

def _apic_frame(mime: str, pictype: int, img: bytes) -> bytes:
    payload = bytes([0]) + mime.encode() + b"\x00" + bytes([pictype]) + b"cover\x00" + img
    return _id3v23_frame("APIC", payload)

def id3v23_wrap(mp3_body: bytes, frames: list[bytes]) -> bytes:
    body = b"".join(frames)
    return b"ID3" + bytes([3, 0, 0]) + _syncsafe(len(body)) + body + mp3_body

def raw_mp3() -> bytes:
    return audio_bytes("mp3")  # no-tag payload (frame sync at head)

# ---------------------------------------------------------------- tag parsing

def _trim(s: str) -> str:
    return s.strip(" \t\r\n\x00")

def _decode_id3_text(enc: int, raw: bytes) -> str:
    """依 model.md §1.3。encoding 0 = Latin-1（Big5 髒檔 → mojibake，刻意）。"""
    if enc == 0:
        return raw.decode("latin-1")
    if enc == 1:
        if len(raw) < 2 or len(raw) % 2 != 0:
            return ""
        if raw[:2] == b"\xff\xfe":
            return raw[2:].decode("utf-16-le", "replace")
        if raw[:2] == b"\xfe\xff":
            return raw[2:].decode("utf-16-be", "replace")
        # 無 BOM：猜（第一組位元組 00 xx → BE；xx 00 → LE）
        if len(raw) >= 2 and raw[0] == 0:
            return raw.decode("utf-16-be", "replace")
        return raw.decode("utf-16-le", "replace")
    if enc == 2:
        if len(raw) % 2 != 0:
            return ""
        return raw.decode("utf-16-be", "replace")
    if enc == 3:
        return raw.decode("utf-8", "replace")
    return ""

def parse_id3v2(data: bytes) -> dict | None:
    """→ tag dict 或 None（不支援/壞掉 → caller 走 fallback）。"""
    if len(data) < 10 or data[:3] != b"ID3":
        return None
    ver_major = data[3]
    flags = data[5]
    size = ((data[6] & 0x7F) << 21) | ((data[7] & 0x7F) << 14) | \
           ((data[8] & 0x7F) << 7) | (data[9] & 0x7F)
    body = data[10:10 + size]
    if ver_major not in (3, 4):
        return None
    if flags & 0x40:  # extended header：v3 4B size, v4 syncsafe
        if len(body) < 4:
            return None
        if ver_major == 3:
            ext = struct.unpack(">I", body[:4])[0] + 4
        else:
            ext = ((body[0] & 0x7F) << 21) | ((body[1] & 0x7F) << 14) | \
                  ((body[2] & 0x7F) << 7) | (body[3] & 0x7F)
        body = body[ext:]
    out: dict[str, str] = {}
    FRAME_KEY = {b"TIT2": "TITLE", b"TPE1": "ARTIST", b"TALB": "ALBUM",
                 b"TPE2": "ALBUMARTIST", b"TRCK": "TRACKNUMBER",
                 b"TPOS": "DISCNUMBER", b"TYER": "YEAR", b"TDRC": "DATE",
                 b"TCMP": "COMPILATION", b"TCP": "COMPILATION"}
    i = 0
    while i + 10 <= len(body):
        fid = body[i:i+4]
        if fid == b"\x00\x00\x00\x00":
            break
        if ver_major == 3:
            fsize = struct.unpack(">I", body[i+4:i+8])[0]
        else:
            b4 = body[i+4:i+8]
            fsize = ((b4[0] & 0x7F) << 21) | ((b4[1] & 0x7F) << 14) | \
                    ((b4[2] & 0x7F) << 7) | (b4[3] & 0x7F)
        fdata = body[i+10:i+10+fsize]
        if fid in FRAME_KEY:
            if len(fdata) < 1:
                i += 10 + fsize
                continue
            enc = fdata[0]
            raw = fdata[1:].split(b"\x00")[0]  # 只取第一個 null 結尾字串
            val = _trim(_decode_id3_text(enc, raw))
            key = FRAME_KEY[fid]
            if val and key not in out:
                out[key] = val
        i += 10 + fsize
    return out

def parse_flac_tags(data: bytes) -> dict | None:
    if data[:4] != b"fLaC":
        return None
    i = 4
    comments: dict[str, str] = {}
    while i + 4 <= len(data):
        last = data[i] & 0x80
        btype = data[i] & 0x7F
        blen = int.from_bytes(data[i+1:i+4], "big")
        block = data[i+4:i+4+blen]
        if btype == 4:  # VORBIS_COMMENT
            j = struct.unpack("<I", block[:4])[0]
            j += 4
            count = struct.unpack("<I", block[j:j+4])[0]
            j += 4
            for _ in range(count):
                vlen = struct.unpack("<I", block[j:j+4])[0]
                j += 4
                kv = block[j:j+vlen].decode("utf-8", "replace")
                j += vlen
                if "=" in kv:
                    k, v = kv.split("=", 1)
                    k = k.upper()
                    if k not in comments:
                        comments[k] = _trim(v)
        if last:
            break
        i += 4 + blen
    return comments

def _parse_vorbis_comment_struct(buf: bytes) -> dict[str, str]:
    """從 magic 之後解析 vendor/count/kv。"""
    comments: dict[str, str] = {}
    j = struct.unpack("<I", buf[:4])[0] + 4
    count = struct.unpack("<I", buf[j:j+4])[0]
    j += 4
    for _ in range(count):
        vlen = struct.unpack("<I", buf[j:j+4])[0]
        j += 4
        kv = buf[j:j+vlen].decode("utf-8", "replace")
        j += vlen
        if "=" in kv:
            k, v = kv.split("=", 1)
            k = k.upper()
            if k not in comments:
                comments[k] = _trim(v)
    return comments

def parse_ogg_tags(data: bytes) -> dict | None:
    if data[:4] != b"OggS":
        return None
    window = data[:65536]
    for magic, is_opus in ((b"OpusTags", True), (b"\x03vorbis", False)):
        pos = window.find(magic)
        if pos >= 0:
            return _parse_vorbis_comment_struct(window[pos + len(magic):])
    return {}

def _mp4_boxes(buf: bytes):
    i = 0
    while i + 8 <= len(buf):
        size = struct.unpack(">I", buf[i:i+4])[0]
        btype = buf[i+4:i+8]
        hdr = 8
        if size == 1:
            if i + 16 > len(buf):
                break
            size = struct.unpack(">Q", buf[i+8:i+16])[0]
            hdr = 16
        elif size == 0:
            size = len(buf) - i
        yield btype, buf[i+hdr:i+size], i + size <= len(buf)
        i += size

def parse_m4a_tags(data: bytes) -> dict | None:
    found_moov = False
    ilst_payload = None
    def walk(buf: bytes, inside_meta: bool = False):
        nonlocal found_moov, ilst_payload
        for btype, payload, ok in _mp4_boxes(buf):
            if not ok:
                continue
            if btype == b"moov":
                found_moov = True
                walk(payload)
            elif btype == b"udta":
                walk(payload)
            elif btype == b"meta":  # meta 有 4B version/flags
                walk(payload[4:], True)
            elif inside_meta and btype == b"ilst":
                ilst_payload = payload
    walk(data)
    if not found_moov:
        return None
    if ilst_payload is None:
        return {}
    KEY = {b"\xa9nam": "TITLE", b"\xa9ART": "ARTIST", b"\xa9alb": "ALBUM",
           b"aART": "ALBUMARTIST", b"\xa9day": "YEAR", b"cpil": "COMPILATION"}
    NUM = {b"trkn": "TRACKNUMBER", b"disk": "DISCNUMBER"}
    out: dict[str, str] = {}
    for btype, payload, ok in _mp4_boxes(ilst_payload):
        if not ok:
            continue
        if btype in KEY:
            for dtype, ddata, dok in _mp4_boxes(payload):
                if dok and dtype == b"data" and len(ddata) >= 9:
                    out[KEY[btype]] = _trim(ddata[8:].decode("utf-8", "replace"))
        elif btype in NUM:
            for dtype, ddata, dok in _mp4_boxes(payload):
                if dok and dtype == b"data" and len(ddata) >= 6:
                    n = struct.unpack(">H", ddata[4:6])[0]
                    if n:
                        out[NUM[btype]] = str(n)
    return out

# ---------------------------------------------------------------- scanner

UNKNOWN_ARTIST = "<Unknown Artist>"
NO_ALBUM = "<No Album>"

def tag_dict_to_fields(tags: dict[str, str]) -> dict:
    f: dict = {}
    f["title"] = tags.get("TITLE")
    f["artist"] = tags.get("ARTIST")
    f["album_artist"] = tags.get("ALBUMARTIST")
    f["album"] = tags.get("ALBUM")
    def num(s):
        if s is None: return None
        head = ""
        for ch in s:
            if ch.isdigit(): head += ch
            else: break
        return int(head) if head else None
    f["track_no"] = num(tags.get("TRACKNUMBER"))
    f["disc"] = num(tags.get("DISCNUMBER"))
    y = tags.get("YEAR") or tags.get("DATE")
    f["year"] = int(y[:4]) if y and len(y) >= 4 and y[:4].isdigit() else None
    f["compilation"] = tags.get("COMPILATION") == "1"
    return f

def parse_tags(fmt: str, data: bytes) -> tuple[dict | None, bool]:
    """→ (fields or None, tag_ok)。None+False = BAD_CONTAINER。{}+False = 壞 tag。"""
    if fmt == "flac":
        if data[:4] != b"fLaC":
            return None, False
        tags = parse_flac_tags(data)
    elif fmt == "mp3":
        tags = parse_id3v2(data)
        if tags is None:  # 無 ID3 → 檢查 frame sync
            if len(data) >= 2 and data[0] == 0xFF and (data[1] & 0xE0) == 0xE0:
                tags = {}
            else:
                return None, False
    elif fmt == "m4a":
        tags = parse_m4a_tags(data)
        if tags is None:
            return None, False
    elif fmt in ("ogg", "opus"):
        tags = parse_ogg_tags(data)
        if tags is None:
            return None, False
        if fmt == "ogg" and b"\x03vorbis" not in data[:65536] and b"OpusTags" not in data[:65536]:
            pass  # 空註解 OK
    elif fmt == "wav":
        if data[:4] != b"RIFF" or data[8:12] != b"WAVE":
            return None, False
        tags = {}
    else:
        raise ValueError(fmt)
    if tags is None:
        tags = {}
    return tag_dict_to_fields(tags), len(tags) > 0

def fmt_for(name: str) -> str | None:
    ext = name.rsplit(".", 1)[-1].lower() if "." in name else ""
    return {"flac": "flac", "mp3": "mp3", "m4a": "m4a", "mp4": "m4a",
            "ogg": "ogg", "opus": "opus", "wav": "wav"}.get(ext)

FILENAME_PAT = __import__("re").compile(r"^(\d{1,3})\s-\s(.+)$")

def scan_tree(root: Path) -> dict:
    tracks: list[dict] = []
    errors: list[dict] = []
    playlists: list[dict] = []
    all_files: list[str] = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        for fn in sorted(filenames):
            rel = (Path(dirpath).relative_to(root) / fn).as_posix()
            all_files.append(rel)
    for rel in all_files:
        if rel.lower().endswith(".m3u8"):
            playlists.append(parse_m3u8(root, rel))
            continue
        fmt = fmt_for(rel)
        if fmt is None:
            continue
        data = (root / rel).read_bytes()
        fields, tag_ok = parse_tags(fmt, data)
        if fields is None:
            errors.append({"code": "BAD_CONTAINER",
                           "message": f"not a valid {fmt} file", "path": rel})
            continue
        t = make_track(rel, fmt, len(data), fields, tag_ok)
        tracks.append(t)
    albums = group_albums(tracks)
    return {
        "albums": sorted(albums, key=lambda a: (a["albumArtist"], a["name"])),
        "errors": sorted(errors, key=lambda e: e["path"]),
        "playlists": sorted(playlists, key=lambda p: p["path"]),
        "tracks": sorted(tracks, key=lambda t: t["path"]),
    }

def make_track(rel: str, fmt: str, size: int, fields: dict | None, tag_ok: bool) -> dict:
    segs = rel.split("/")
    fname = segs[-1]
    stem = fname.rsplit(".", 1)[0] if "." in fname else fname
    fb_title, fb_track_no = stem, None
    m = FILENAME_PAT.match(stem)
    if m:
        fb_track_no = int(m.group(1).lstrip("0") or "0")
        fb_title = m.group(2)
    fb_album_artist = segs[0] if len(segs) >= 3 else UNKNOWN_ARTIST
    fb_album = segs[-2] if len(segs) >= 2 else NO_ALBUM
    if not tag_ok or fields is None:
        fields = {}
    artist = fields.get("artist") or fields.get("album_artist") or fb_album_artist
    album_artist = fields.get("album_artist") or fields.get("artist") or fb_album_artist
    album = fields.get("album") or fb_album
    title = fields.get("title") or fb_title
    track_no = fields.get("track_no") if fields.get("track_no") is not None else fb_track_no
    year = fields.get("year")
    disc = fields.get("disc") or 1
    ok = tag_ok and (fields.get("title") or fields.get("artist")
                     or fields.get("album") or fields.get("album_artist"))
    compilation = bool(fields.get("compilation")) or \
                  (album_artist.lower() == "various artists")
    return {
        "album": album, "albumArtist": album_artist,
        "albumId": f"alb|{album_artist}|{album}",
        "artist": artist, "disc": disc, "durationMs": None, "format": fmt,
        "id": rel, "path": rel, "sizeBytes": size, "tagOk": bool(ok),
        "title": title, "trackNo": track_no, "year": year,
        "_compilation": compilation,
    }

def group_albums(tracks: list[dict]) -> list[dict]:
    by_id: dict[str, list[dict]] = {}
    for t in tracks:
        by_id.setdefault(t["albumId"], []).append(t)
    albums = []
    for aid, ts in by_id.items():
        ts.sort(key=lambda t: t["path"])
        year = next((t["year"] for t in ts if t["year"] is not None), None)
        art = next((t["id"] for t in ts if t["tagOk"]), None)
        albums.append({
            "albumArtist": ts[0]["albumArtist"], "artTrackId": art,
            "compilation": any(t["_compilation"] for t in ts),
            "id": aid, "name": ts[0]["album"], "trackCount": len(ts),
            "year": year,
        })
    return albums

def _extinf_to_ms(s: str) -> int | None:
    """無浮點：'213.5'→213500；'5'→5000；'.5'→500；'5.4005'→5400（毫秒截斷）。
    非法（空/負/非數字）→ None。"""
    s = s.strip()
    if not s:
        return None
    neg = s.startswith("-")
    if neg:
        s = s[1:]
    if "." in s:
        ip, fp = s.split(".", 1)
    else:
        ip, fp = s, ""
    if not ip.isdigit() or (fp and not fp.isdigit()):
        return None
    ip = int(ip) if ip else 0
    fp = (fp + "000")[:3]  # 補到 3 位＝毫秒；超出截斷
    v = ip * 1000 + int(fp)
    return -v if neg else v

def parse_m3u8(root: Path, rel: str) -> dict:
    raw = (root / rel).read_bytes()
    text = raw.decode("utf-8", "replace").lstrip("\ufeff")
    base = "/".join(rel.split("/")[:-1])
    track_paths: set[str] = set()
    for dirpath, _, filenames in os.walk(root):
        for fn in filenames:
            p = (Path(dirpath).relative_to(root) / fn).as_posix()
            if fmt_for(p):
                track_paths.add(p)
    items: list[dict] = []
    pending_dur_ms = None
    for line in text.replace("\r\n", "\n").split("\n"):
        line = line.strip()
        if not line:
            continue
        if line.startswith("#"):
            if line.startswith("#EXTINF:"):
                rest = line[len("#EXTINF:"):]
                dur_s = rest.split(",", 1)[0]
                pending_dur_ms = _extinf_to_ms(dur_s)
            continue
        ref = line.replace("\\", "/")
        while ref.startswith("./"):
            ref = ref[2:]
        track_id = None
        if not ref.startswith("/"):
            resolved = _norm_path(f"{base}/{ref}" if base else ref)
            if resolved is not None and resolved in track_paths:
                track_id = resolved
        items.append({
            "durationMs": pending_dur_ms,
            "missing": track_id is None,
            "position": len(items), "ref": ref, "trackId": track_id,
        })
        pending_dur_ms = None
    name = rel.split("/")[-1][:-5]
    return {"id": rel, "items": items, "name": name, "path": rel}

def _norm_path(p: str) -> str | None:
    out: list[str] = []
    for seg in p.split("/"):
        if seg in ("", "."):
            continue
        if seg == "..":
            if not out:
                return None
            out.pop()
        else:
            out.append(seg)
    return "/".join(out)

def canonical(obj) -> str:
    s = json.dumps(obj, indent=2, sort_keys=True, ensure_ascii=False,
                   separators=(",", ": "))
    return s + "\n"

# ---------------------------------------------------------------- cases

def write(rel_dir: Path, name: str, data: bytes):
    p = rel_dir / name
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_bytes(data)

def build_cases() -> list[str]:
    """回傳案例名單；每案例 lib/ 由呼叫端建。"""
    return [
        "flac_full_tags", "flac_no_tags", "mp3_id3v23_utf16", "mp3_id3v24_utf8",
        "mp3_id3v23_big5_dirty", "mp3_no_tags", "mp3_multiple_covers",
        "mp3_bad_container", "flac_bad_container", "m4a_itunes_tags",
        "opus_ogg_tags", "ogg_vorbis_tags", "wav_untagged", "va_compilation",
        "deep_path_no_tags", "filename_track_patterns", "unknown_ext_ignored",
        "nested_album_dirs", "m3u8_empty", "m3u8_extinf_relative",
        "m3u8_crlf_bom", "m3u8_absolute_paths", "m3u8_missing_refs",
        "m3u8_unicode_names", "m3u8_malformed_extinf", "m3u8_windows_backslash",
    ]

def populate(name: str, lib: Path):
    F = lambda n, meta=None, fmt="flac": write(lib, n, audio_bytes(fmt, meta))
    if name == "flac_full_tags":
        F("Aurora/Northern Lights/01 - Rise.flac",
          {"title": "Rise", "artist": "Aurora", "album": "Northern Lights",
           "album_artist": "Aurora", "track_number": "1", "date": "2021"})
    elif name == "flac_no_tags":
        F("Aurora/Northern Lights/01 - Rise.flac")
    elif name == "mp3_id3v23_utf16":
        F("陳綺貞/時間的歌/03 - 旅行的意義.mp3",
          {"title": "旅行的意義", "artist": "陳綺貞", "album": "時間的歌"},
          fmt="mp3")
    elif name == "mp3_id3v24_utf8":
        F("Kyary/Jelly/02 - Ninjya.mp3",
          {"title": "にんじゃ" , "artist": "Kyary", "album": "Jelly"},
          fmt="mp3_utf8_tags")
    elif name == "mp3_id3v23_big5_dirty":
        body = raw_mp3()
        frames = [
            _text_frame("TIT2", 0, "晴天".encode("big5")),
            _text_frame("TPE1", 0, "周杰倫".encode("big5")),
            _text_frame("TALB", 0, "葉惠美".encode("big5")),
        ]
        write(lib, "周杰倫/葉惠美/03 - 晴天.mp3", id3v23_wrap(body, frames))
    elif name == "mp3_no_tags":
        write(lib, "Aurora/Northern Lights/01 - Rise.mp3", raw_mp3())
    elif name == "mp3_multiple_covers":
        body = raw_mp3()
        frames = [
            _text_frame("TIT2", 3, "Covered".encode()),
            _text_frame("TPE1", 3, "The Band".encode()),
            _text_frame("TALB", 3, "Sleeves".encode()),
            _apic_frame("image/png", 3, PNG1x1),
            _apic_frame("image/png", 4, PNG1x1),
        ]
        write(lib, "The Band/Sleeves/01 - Covered.mp3", id3v23_wrap(body, frames))
    elif name == "mp3_bad_container":
        write(lib, "X/Y/01 - Fake.mp3", b"this is just text, no sync ff fb here")
    elif name == "flac_bad_container":
        write(lib, "X/Y/01 - Fake.flac", b"not a flac at all")
    elif name == "m4a_itunes_tags":
        F("Becko/Vector/02 - North.m4a",
          {"title": "North", "artist": "Becko", "album": "Vector",
           "album_artist": "Becko", "track": "2/9", "disc": "1",
           "date": "2019"}, fmt="m4a")
    elif name == "opus_ogg_tags":
        F("Lofi/Beats/01 - Rain.opus",
          {"title": "Rain", "artist": "Lofi", "album": "Beats"}, fmt="opus")
    elif name == "ogg_vorbis_tags":
        F("Lofi/Beats/02 - Snow.ogg",
          {"title": "Snow", "artist": "Lofi", "album": "Beats"}, fmt="ogg")
    elif name == "wav_untagged":
        F("Sfx/Pack/01 - Kick.wav", None, fmt="wav")
    elif name == "va_compilation":
        F("Various Artists/OST 2020/01 - First.flac",
          {"title": "First", "artist": "Alpha", "album_artist": "Various Artists",
           "album": "OST 2020", "compilation": "1"})
        F("Various Artists/OST 2020/02 - Second.flac",
          {"title": "Second", "artist": "Beta", "album_artist": "Various Artists",
           "album": "OST 2020", "compilation": "1"})
    elif name == "deep_path_no_tags":
        F("Various Artists/Dream Mixtape/07 - Unknown.flac")
    elif name == "filename_track_patterns":
        F("A/B/05 - Leading Zero.flac")
        F("A/B/12-Irregular.flac")
        F("A/B/99 No Dash.flac")
        F("A/B/No Number.flac")
        F("C/onlyone.flac")
        F("loose.flac")
    elif name == "unknown_ext_ignored":
        write(lib, "Docs/readme.txt", b"hello")
        write(lib, "A/B/cover.jpg", PNG1x1)
        F("A/B/01 - Real.flac")
    elif name == "nested_album_dirs":
        F("Ken/Album One/01 - A.flac",
          {"title": "A", "artist": "Ken", "album": "Album One"})
        F("Ken/Album Two/01 - B.flac",
          {"title": "B", "artist": "Ken", "album": "Album Two"})
    elif name == "m3u8_empty":
        write(lib, "Playlists/empty.m3u8", b"")
    elif name == "m3u8_extinf_relative":
        F("Aurora/Northern Lights/01 - Rise.flac",
          {"title": "Rise", "artist": "Aurora", "album": "Northern Lights"})
        write(lib, "Playlists/best.m3u8",
              b"#EXTM3U\n#EXTINF:213.5,Rise\n../Aurora/Northern Lights/01 - Rise.flac\n")
    elif name == "m3u8_crlf_bom":
        F("Aurora/Northern Lights/01 - Rise.flac",
          {"title": "Rise", "artist": "Aurora", "album": "Northern Lights"})
        write(lib, "Playlists/crlf.m3u8",
              "\ufeff#EXTM3U\r\n#EXTINF:100,Title\r\n../Aurora/Northern Lights/01 - Rise.flac\r\n".encode("utf-8"))
    elif name == "m3u8_absolute_paths":
        F("Aurora/Northern Lights/01 - Rise.flac",
          {"title": "Rise", "artist": "Aurora", "album": "Northern Lights"})
        write(lib, "Playlists/abs.m3u8",
              b"#EXTM3U\n/Music/Aurora/Northern Lights/01 - Rise.flac\n")
    elif name == "m3u8_missing_refs":
        F("Aurora/Northern Lights/01 - Rise.flac",
          {"title": "Rise", "artist": "Aurora", "album": "Northern Lights"})
        write(lib, "Playlists/gaps.m3u8",
              b"#EXTM3U\n../Aurora/Northern Lights/01 - Rise.flac\n../Nowhere/02 - Ghost.flac\n")
    elif name == "m3u8_unicode_names":
        F("陳綺貞/時間的歌/03 - 旅行的意義.flac",
          {"title": "旅行的意義", "artist": "陳綺貞", "album": "時間的歌"})
        write(lib, "清單/我的最愛.m3u8",
              "#EXTM3U\n#EXTINF:260,旅行\n../陳綺貞/時間的歌/03 - 旅行的意義.flac\n".encode("utf-8"))
    elif name == "m3u8_malformed_extinf":
        F("A/B/01 - X.flac", {"title": "X", "artist": "A", "album": "B"})
        write(lib, "Playlists/weird.m3u8",
              b"#EXTM3U\n#EXTINF:,NoDur\n#EXTINF:abc,NotNum\n../A/B/01 - X.flac\n#EXTINF:5.4,Second\n../A/B/01 - X.flac\n")
    elif name == "m3u8_windows_backslash":
        F("Aurora/Northern Lights/01 - Rise.flac",
          {"title": "Rise", "artist": "Aurora", "album": "Northern Lights"})
        write(lib, "Playlists/win.m3u8",
              b"#EXTM3U\n..\\Aurora\\Northern Lights\\01 - Rise.flac\n")

def main():
    if CASES.exists():
        shutil.rmtree(CASES)
    names = build_cases()
    for name in names:
        lib = CASES / name / "lib"
        lib.mkdir(parents=True)
        populate(name, lib)
        result = scan_tree(lib)
        for t in result["tracks"]:
            t.pop("_compilation")
        for e in result["errors"]:
            e["message"] = ""   # 契約豁免：實作自由文字，不參與 byte-compare
        (CASES / name / "expected.json").write_text(canonical(result), encoding="utf-8")
    # sanity asserts（規格自檢，不是測試框架）
    def expect(cond, msg):
        if not cond:
            raise AssertionError(msg)
    def load(name):
        return json.loads((CASES / name / "expected.json").read_text())
    r = load("flac_full_tags")
    expect(r["tracks"][0]["tagOk"] is True, "flac_full_tags tagOk")
    expect(r["tracks"][0]["year"] == 2021, "flac year from DATE")
    r = load("mp3_id3v23_utf16")
    expect(r["tracks"][0]["title"] == "旅行的意義", f"utf16 title: {r['tracks'][0]}")
    r = load("mp3_id3v24_utf8")
    expect(r["tracks"][0]["title"] == "にんじゃ", "v2.4 utf8 title")
    r = load("mp3_id3v23_big5_dirty")
    t = r["tracks"][0]
    expect(t["tagOk"] is True and t["title"] != "晴天", f"big5 → latin1 mojibake: {t}")
    r = load("mp3_multiple_covers")
    expect(r["tracks"][0]["title"] == "Covered", "covers parsed, title ok")
    r = load("va_compilation")
    expect(r["albums"][0]["compilation"] is True, "VA compilation")
    expect(len(r["albums"]) == 1, "VA one album")
    r = load("mp3_bad_container")
    expect(len(r["errors"]) == 1 and r["errors"][0]["code"] == "BAD_CONTAINER", "bad mp3")
    r = load("unknown_ext_ignored")
    expect(len(r["tracks"]) == 1 and not r["errors"], "ext filter")
    r = load("m3u8_extinf_relative")
    expect(r["playlists"][0]["items"][0]["trackId"] == "Aurora/Northern Lights/01 - Rise.flac", "m3u8 resolve")
    expect(r["playlists"][0]["items"][0]["durationMs"] == 213500, "extinf ms")
    r = load("m3u8_missing_refs")
    expect(r["playlists"][0]["items"][1]["missing"] is True, "missing ref")
    r = load("filename_track_patterns")
    by = {t["title"]: t for t in r["tracks"]}
    expect(by["Leading Zero"]["trackNo"] == 5, "leading zero strip")
    expect(by["12-Irregular"]["trackNo"] is None, "no space-dash → no trackNo")
    print(f"OK: {len(names)} cases generated, all sanity asserts passed")

if __name__ == "__main__":
    main()
