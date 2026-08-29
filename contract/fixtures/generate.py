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

# ---------------------------------------------------------------- 讀取視窗化（model.md §1.8）

CHUNK = 65536


class ByteSource:
    """size + read(offset, length)（裁切到 size）。"""
    size: int

    def read(self, offset: int, length: int) -> bytes:
        raise NotImplementedError


class BytesSource(ByteSource):
    def __init__(self, data: bytes):
        self.data = data
        self.size = len(data)

    def read(self, offset: int, length: int) -> bytes:
        return self.data[offset:offset + length]


class FileSource(ByteSource):
    def __init__(self, path: Path):
        self.path = path
        self.size = path.stat().st_size

    def read(self, offset: int, length: int) -> bytes:
        with open(self.path, "rb") as f:
            f.seek(offset)
            return f.read(length)


class ChunkedReader:
    """64 KiB 對齊 chunk、每 chunk 抓一次；三實作同算法 → 觸碰 chunk 集合一致。"""

    def __init__(self, src: ByteSource):
        self.src = src
        self.size = src.size
        self._chunks: dict[int, bytes] = {}
        self.fetches = 0

    def bytes(self, off: int, length: int) -> bytes:
        if off < 0 or off >= self.size or length <= 0:
            return b""
        end = min(self.size, off + length)
        parts = []
        for k in range(off // CHUNK, (end - 1) // CHUNK + 1):
            if k not in self._chunks:
                start = k * CHUNK
                self._chunks[k] = self.src.read(start, min(CHUNK, self.size - start))
                self.fetches += 1
            c = self._chunks[k]
            parts.append(c[max(off, k * CHUNK) - k * CHUNK:min(end, (k + 1) * CHUNK) - k * CHUNK])
        return b"".join(parts)


def _u32be(b: bytes) -> int: return struct.unpack(">I", b)[0]
def _u32le(b: bytes) -> int: return struct.unpack("<I", b)[0]
def _u64be(b: bytes) -> int: return struct.unpack(">Q", b)[0]
def _ss(b: bytes) -> int:
    return ((b[0] & 0x7F) << 21) | ((b[1] & 0x7F) << 14) | ((b[2] & 0x7F) << 7) | (b[3] & 0x7F)


RG_KEYS = {"REPLAYGAIN_TRACK_GAIN", "REPLAYGAIN_ALBUM_GAIN"}


def parse_gain_mb(s: str | None) -> int | None:
    """model.md §1.9：'-6.54 dB' → -654；無浮點；無整數位數字 → None。"""
    if s is None:
        return None
    t = s.strip()
    i = 0
    sign = 1
    if i < len(t) and t[i] in "+-":
        sign = -1 if t[i] == "-" else 1
        i += 1
    j = i
    while j < len(t) and t[j].isdigit() and t[j].isascii():
        j += 1
    if j == i:
        return None
    whole = int(t[i:j])
    frac = 0
    if j < len(t) and t[j] == ".":
        k = j + 1
        digits = ""
        while k < len(t) and t[k].isdigit() and t[k].isascii() and len(digits) < 2:
            digits += t[k]
            k += 1
        frac = int((digits + "00")[:2])
    return sign * (whole * 100 + frac)


def _id3_split_nul(raw: bytes, enc: int) -> tuple[bytes, bytes]:
    """依編碼切第一個終止符：Latin-1/UTF-8 = 1 NUL；UTF-16 = 對齊的 00 00。回 (前段, 後段)。"""
    if enc in (1, 2):
        i = 0
        while i + 1 < len(raw):
            if raw[i] == 0 and raw[i + 1] == 0:
                return raw[:i], raw[i + 2:]
            i += 2
        return raw, b""
    i = raw.find(b"\x00")
    return (raw, b"") if i < 0 else (raw[:i], raw[i + 1:])


FRAME_KEY = {b"TIT2": "TITLE", b"TPE1": "ARTIST", b"TALB": "ALBUM",
             b"TPE2": "ALBUMARTIST", b"TRCK": "TRACKNUMBER",
             b"TPOS": "DISCNUMBER", b"TYER": "YEAR", b"TDRC": "DATE",
             b"TCMP": "COMPILATION", b"TCP": "COMPILATION"}


def parse_id3v2(r: ChunkedReader) -> dict | None:
    """→ tag dict 或 None（不支援/壞掉 → caller 走 fallback）。只讀 frame header，跳過非關注 payload。"""
    if r.size < 10:
        return None
    h = r.bytes(0, 10)
    if h[:3] != b"ID3":
        return None
    ver_major = h[3]
    flags = h[5]
    body_start = 10
    body_end = min(r.size, 10 + _ss(h[6:10]))
    if ver_major not in (3, 4):
        return None
    if flags & 0x40:  # extended header：v3 4B size, v4 syncsafe
        if body_end - body_start < 4:
            return None
        e = r.bytes(body_start, 4)
        ext = _u32be(e) + 4 if ver_major == 3 else _ss(e)
        body_start = min(body_end, body_start + ext)
    out: dict[str, str] = {}
    i = body_start
    while i + 10 <= body_end:
        fh = r.bytes(i, 10)
        fid = fh[:4]
        if fid == b"\x00\x00\x00\x00":
            break
        fsize = _u32be(fh[4:8]) if ver_major == 3 else _ss(fh[4:8])
        fstart = i + 10
        fend = min(body_end, fstart + fsize)
        if fid in FRAME_KEY and fend > fstart:
            fdata = r.bytes(fstart, fend - fstart)
            enc = fdata[0]
            raw = fdata[1:].split(b"\x00")[0]  # 只取第一個 null 結尾字串
            val = _trim(_decode_id3_text(enc, raw))
            key = FRAME_KEY[fid]
            if val and key not in out:
                out[key] = val
        elif fid == b"TXXX" and fend > fstart:  # §1.9：description 決定鍵
            fdata = r.bytes(fstart, fend - fstart)
            enc = fdata[0]
            desc_b, rest = _id3_split_nul(fdata[1:], enc)
            key = _trim(_decode_id3_text(enc, desc_b)).upper()
            if key in RG_KEYS:
                val_b, _ = _id3_split_nul(rest, enc)
                val = _trim(_decode_id3_text(enc, val_b))
                if val and key not in out:
                    out[key] = val
        i = fstart + fsize
    return out


def _vorbis_comments(buf: bytes, j: int, to: int) -> dict[str, str]:
    """從 magic 之後解析 vendor/count/kv（越界即停，回已解析部分）。"""
    comments: dict[str, str] = {}
    if j + 4 > to:
        return comments
    j += _u32le(buf[j:j + 4]) + 4
    if j + 4 > to:
        return comments
    count = _u32le(buf[j:j + 4])
    j += 4
    for _ in range(count):
        if j + 4 > to:
            return comments
        vlen = _u32le(buf[j:j + 4])
        j += 4
        if j + vlen > to:
            return comments
        kv = buf[j:j + vlen].decode("utf-8", "replace")
        j += vlen
        eq = kv.find("=")
        if eq > 0:
            k = kv[:eq].upper()
            if k not in comments:
                comments[k] = _trim(kv[eq + 1:])
    return comments


def parse_flac_tags(r: ChunkedReader) -> dict | None:
    if r.bytes(0, 4) != b"fLaC":
        return None
    i = 4
    comments: dict[str, str] = {}
    while i + 4 <= r.size:
        h = r.bytes(i, 4)
        last = h[0] & 0x80
        btype = h[0] & 0x7F
        blen = int.from_bytes(h[1:4], "big")
        start = i + 4
        end = min(r.size, start + blen)
        if btype == 4 and end > start:  # VORBIS_COMMENT；PICTURE 等跳過
            block = r.bytes(start, end - start)
            for k, v in _vorbis_comments(block, 0, len(block)).items():
                if k not in comments:
                    comments[k] = v
        if last:
            break
        i = start + blen
    return comments


def parse_ogg_tags(r: ChunkedReader) -> dict | None:
    if r.size < 4:
        return None
    window = r.bytes(0, min(CHUNK, r.size))
    if window[:4] != b"OggS":
        return None
    for magic in (b"OpusTags", b"\x03vorbis"):
        pos = window.find(magic)
        if pos >= 0:
            return _vorbis_comments(window, pos + len(magic), len(window))
    return {}


def _mp4_boxes(r: ChunkedReader, frm: int, to: int):
    """只讀 box header；yield (type, payloadStart, payloadEnd)。size < header 或越界 → 停。"""
    i = frm
    while i + 8 <= to:
        h = r.bytes(i, 8)
        size = _u32be(h[:4])
        btype = h[4:8]
        hdr = 8
        if size == 1:
            if i + 16 > to:
                break
            size = _u64be(r.bytes(i + 8, 8))
            hdr = 16
        elif size == 0:
            size = to - i
        if size < hdr or i + size > to:
            break
        yield btype, i + hdr, i + size
        i += size


def parse_m4a_tags(r: ChunkedReader) -> dict | None:
    found_moov = False
    ilst = None

    def walk(frm: int, to: int, inside_meta: bool = False):
        nonlocal found_moov, ilst
        for btype, ps, pe in _mp4_boxes(r, frm, to):
            if btype == b"moov":
                found_moov = True
                walk(ps, pe)
            elif btype == b"udta":
                walk(ps, pe)
            elif btype == b"meta":  # meta 有 4B version/flags
                if pe - ps > 4:
                    walk(ps + 4, pe, True)
            elif inside_meta and btype == b"ilst":
                ilst = (ps, pe)
    walk(0, r.size)
    if not found_moov:
        return None
    if ilst is None:
        return {}
    KEY = {b"\xa9nam": "TITLE", b"\xa9ART": "ARTIST", b"\xa9alb": "ALBUM",
           b"aART": "ALBUMARTIST", b"\xa9day": "YEAR", b"cpil": "COMPILATION"}
    NUM = {b"trkn": "TRACKNUMBER", b"disk": "DISCNUMBER"}
    out: dict[str, str] = {}
    for btype, ps, pe in _mp4_boxes(r, *ilst):
        if btype == b"----":  # §1.9 自由格式：name 決定鍵
            name = None
            dd = None
            for ctype, cs, ce in _mp4_boxes(r, ps, pe):
                if ctype == b"name" and ce - cs > 4:
                    name = _trim(r.bytes(cs + 4, ce - cs - 4).decode("utf-8", "replace")).upper()
                elif ctype == b"data" and ce - cs >= 9 and dd is None:
                    dd = r.bytes(cs, ce - cs)
            if name in RG_KEYS and dd is not None:
                v = _trim(dd[8:].decode("utf-8", "replace"))
                if v and name not in out:
                    out[name] = v
            continue
        key, nkey = KEY.get(btype), NUM.get(btype)
        if key is None and nkey is None:
            continue
        for dtype, ds, de in _mp4_boxes(r, ps, pe):
            if dtype != b"data":
                continue
            dd = r.bytes(ds, de - ds)
            if key is not None and len(dd) >= 9:
                v = _trim(dd[8:].decode("utf-8", "replace"))
                if v and key not in out:
                    out[key] = v
            elif nkey is not None and len(dd) >= 6:
                n = struct.unpack(">H", dd[4:6])[0]
                if n and nkey not in out:
                    out[nkey] = str(n)
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
    f["rg_track_mb"] = parse_gain_mb(tags.get("REPLAYGAIN_TRACK_GAIN"))
    f["rg_album_mb"] = parse_gain_mb(tags.get("REPLAYGAIN_ALBUM_GAIN"))
    return f

def parse_tags(fmt: str, r: ChunkedReader) -> tuple[dict | None, bool]:
    """→ (fields or None, tag_ok)。None+False = BAD_CONTAINER。{}+False = 壞 tag。"""
    if fmt == "flac":
        if r.bytes(0, 4) != b"fLaC":
            return None, False
        tags = parse_flac_tags(r)
    elif fmt == "mp3":
        tags = parse_id3v2(r)
        if tags is None:  # 無 ID3 → 檢查 frame sync
            b2 = r.bytes(0, 2)
            if len(b2) >= 2 and b2[0] == 0xFF and (b2[1] & 0xE0) == 0xE0:
                tags = {}
            else:
                return None, False
    elif fmt == "m4a":
        tags = parse_m4a_tags(r)
        if tags is None:
            return None, False
    elif fmt in ("ogg", "opus"):
        tags = parse_ogg_tags(r)
        if tags is None:
            return None, False
    elif fmt == "wav":
        if not _is_wav(r):
            return None, False
        tags = {}
    else:
        raise ValueError(fmt)
    if tags is None:
        tags = {}
    return tag_dict_to_fields(tags), len(tags) > 0


def _is_wav(r: ChunkedReader) -> bool:
    if r.size < 12:
        return False
    h = r.bytes(0, 12)
    return h[:4] == b"RIFF" and h[8:12] == b"WAVE"

def fmt_for(name: str) -> str | None:
    ext = name.rsplit(".", 1)[-1].lower() if "." in name else ""
    return {"flac": "flac", "mp3": "mp3", "m4a": "m4a", "mp4": "m4a",
            "ogg": "ogg", "opus": "opus", "wav": "wav"}.get(ext)

# ---------------------------------------------------------------- duration

_MP3_BR_M1 = [32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
_MP3_BR_M2 = [8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160]

def parse_duration(fmt: str, r: ChunkedReader) -> int | None:
    """model.md §1.7 / §1.8。整數除法；失敗/<=0 → None。"""
    size = r.size
    if fmt == "flac":
        if size < 8 + 34:
            return None
        d = r.bytes(0, 42)
        if d[:4] != b"fLaC" or (d[4] & 0x7F) != 0:  # 第一個 block 非 STREAMINFO
            return None
        b = d[8:42]
        rate = (b[10] << 12) | (b[11] << 4) | (b[12] >> 4)
        total = ((b[13] & 0xF) << 32) | int.from_bytes(b[14:18], "big")
        if rate == 0 or total == 0:
            return None
        return total * 1000 // rate
    if fmt == "mp3":
        off = 0
        if size >= 3 and r.bytes(0, 3) == b"ID3":
            if size < 10:
                return None
            off = 10 + _ss(r.bytes(6, 4))
        n = min(off + 65536, size - 3) - off
        if n <= 0:
            return None
        buf = r.bytes(off, n + 2)
        for i in range(n):
            if buf[i] != 0xFF or (buf[i + 1] & 0xE0) != 0xE0:
                continue
            ver = (buf[i + 1] >> 3) & 3
            layer = (buf[i + 1] >> 1) & 3
            br = (buf[i + 2] >> 4) & 0xF
            sr = (buf[i + 2] >> 2) & 3
            if ver == 1 or layer != 1 or br in (0, 15) or sr == 3:
                continue
            kbps = (_MP3_BR_M1 if ver == 3 else _MP3_BR_M2)[br - 1]
            return (size - (off + i)) * 8 // kbps
        return None
    if fmt == "m4a":
        def find_mvhd(frm, to):
            for btype, ps, pe in _mp4_boxes(r, frm, to):
                if btype == b"moov":
                    res = find_mvhd(ps, pe)
                    if res is not None:
                        return res
                elif btype == b"mvhd":
                    p = r.bytes(ps, min(pe - ps, 32))
                    if not p:
                        return None
                    if p[0] == 0:
                        if pe - ps < 20:
                            return None
                        return _u32be(p[12:16]), _u32be(p[16:20])
                    if pe - ps < 32:
                        return None
                    return _u32be(p[20:24]), _u64be(p[24:32])
            return None
        res = find_mvhd(0, size)
        if res is None or res[0] == 0 or res[1] == 0:
            return None
        return res[1] * 1000 // res[0]
    if fmt in ("ogg", "opus"):
        tail_off = max(0, size - CHUNK)
        tail = r.bytes(tail_off, size - tail_off)
        p = tail.rfind(b"OggS")
        if p < 0:
            return None
        p += tail_off
        if size < p + 14:
            return None
        granule = int.from_bytes(r.bytes(p + 6, 8), "little")
        head = r.bytes(0, min(CHUNK, size))
        if fmt == "opus":
            h = head.find(b"OpusHead")
            if h < 0 or size < h + 12:
                return None
            preskip = int.from_bytes(r.bytes(h + 10, 2), "little")
            v = (granule - preskip) * 1000 // 48000
            return v if v > 0 else None
        v = head.find(b"\x01vorbis")
        if v < 0 or size < v + 16:
            return None
        rate = _u32le(r.bytes(v + 12, 4))
        if rate == 0 or granule == 0:
            return None
        return granule * 1000 // rate
    if fmt == "wav":
        if not _is_wav(r):
            return None
        byte_rate = data_size = None
        i = 12
        while i + 8 <= size:
            ch = r.bytes(i, 8)
            cid = ch[:4]
            csz = _u32le(ch[4:8])
            if cid == b"fmt " and csz >= 12:
                if i + 20 <= size:
                    byte_rate = _u32le(r.bytes(i + 16, 4))
            elif cid == b"data":
                data_size = csz
            i += 8 + csz + (csz & 1)
        if not byte_rate or data_size is None:
            return None
        return data_size * 1000 // byte_rate
    return None


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
        r = ChunkedReader(FileSource(root / rel))
        fields, tag_ok = parse_tags(fmt, r)
        if fields is None:
            errors.append({"code": "BAD_CONTAINER",
                           "message": f"not a valid {fmt} file", "path": rel})
            continue
        t = make_track(rel, fmt, r.size, fields, tag_ok, parse_duration(fmt, r))
        tracks.append(t)
    albums = group_albums(tracks)
    return {
        "albums": sorted(albums, key=lambda a: (a["albumArtist"], a["name"])),
        "errors": sorted(errors, key=lambda e: e["path"]),
        "playlists": sorted(playlists, key=lambda p: p["path"]),
        "tracks": sorted(tracks, key=lambda t: t["path"]),
    }

def make_track(rel: str, fmt: str, size: int, fields: dict | None, tag_ok: bool,
               duration_ms: int | None = None) -> dict:
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
        "artist": artist, "disc": disc, "durationMs": duration_ms, "format": fmt,
        "id": rel, "path": rel,
        "replayGainAlbumMb": fields.get("rg_album_mb"),
        "replayGainTrackMb": fields.get("rg_track_mb"),
        "sizeBytes": size, "tagOk": bool(ok),
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
        "replaygain_tags",
    ]

def _mp4_box(t: bytes, payload: bytes) -> bytes:
    return struct.pack(">I", 8 + len(payload)) + t + payload


def flac_with_comments(src: bytes, extra: list[tuple[str, str]]) -> bytes:
    """把 extra 追加到 FLAC 的 VORBIS_COMMENT block（重寫 block 長度；其餘 bytes 原樣）。"""
    i = 4
    while True:
        hdr = src[i]
        blen = int.from_bytes(src[i + 1:i + 4], "big")
        if hdr & 0x7F == 4:
            block = src[i + 4:i + 4 + blen]
            vl = struct.unpack("<I", block[:4])[0]
            vendor = block[4:4 + vl]
            j = 4 + vl
            count = struct.unpack("<I", block[j:j + 4])[0]
            j += 4
            items = []
            for _ in range(count):
                n = struct.unpack("<I", block[j:j + 4])[0]
                items.append(block[j + 4:j + 4 + n])
                j += 4 + n
            items += [f"{k}={v}".encode() for k, v in extra]
            nb = struct.pack("<I", len(vendor)) + vendor + struct.pack("<I", len(items)) + \
                b"".join(struct.pack("<I", len(it)) + it for it in items)
            return src[:i] + bytes([hdr]) + len(nb).to_bytes(3, "big") + nb + src[i + 4 + blen:]
        if hdr & 0x80:
            raise ValueError("no VORBIS_COMMENT block")
        i += 4 + blen


def _txxx(enc: int, desc: str, value: str) -> bytes:
    if enc == 1:
        d = b"\xff\xfe" + desc.encode("utf-16-le") + b"\x00\x00"
        v = b"\xff\xfe" + value.encode("utf-16-le") + b"\x00\x00"
    else:
        d = desc.encode("latin-1") + b"\x00"
        v = value.encode("latin-1") + b"\x00"
    return _id3v23_frame("TXXX", bytes([enc]) + d + v)


def _m4a_freeform(name: str, value: str) -> bytes:
    return _mp4_box(b"----",
                    _mp4_box(b"mean", bytes(4) + b"com.apple.iTunes") +
                    _mp4_box(b"name", bytes(4) + name.encode()) +
                    _mp4_box(b"data", struct.pack(">II", 1, 0) + value.encode()))


def populate_replaygain(lib: Path):
    """§1.9 合成檔（不需 ffmpeg）：FLAC 追加 comment、MP3 TXXX（Latin-1 + UTF-16）、M4A ---- atom。"""
    flac_a = (HERE / "sync_assets" / "flac_a").read_bytes()
    write(lib, "RG/Album/01 - Flac.flac", flac_with_comments(flac_a, [
        ("REPLAYGAIN_TRACK_GAIN", "-6.54 dB"), ("REPLAYGAIN_ALBUM_GAIN", "+2.1 dB"),
        ("REPLAYGAIN_TRACK_PEAK", "0.98")]))
    write(lib, "RG/Album/02 - Flac Odd.flac", flac_with_comments(flac_a, [
        ("replaygain_track_gain", "n/a"), ("REPLAYGAIN_ALBUM_GAIN", "3.567"),
        ("REPLAYGAIN_TRACK_GAIN", "-12 dB")]))  # 同鍵第一個勝（n/a → null）；截斷第三位
    body = b"\xff\xfb\x90\x00" + bytes(4000)
    write(lib, "RG/Album/03 - Mp3.mp3", id3v23_wrap(body, [
        _text_frame("TIT2", 3, "Gainy".encode()), _text_frame("TPE1", 3, "Aurora".encode()),
        _text_frame("TALB", 3, "Album".encode()),
        _txxx(0, "replaygain_track_gain", "-7.25 dB"),
        _txxx(1, "REPLAYGAIN_ALBUM_GAIN", "+0.5 dB"),
        _txxx(0, "some_other", "ignored"),
    ]))
    ilst = (_mp4_box(b"\xa9nam", _mp4_box(b"data", struct.pack(">II", 1, 0) + b"Boxed")) +
            _m4a_freeform("replaygain_track_gain", "-3.00 dB") +
            _m4a_freeform("REPLAYGAIN_ALBUM_GAIN", "-.5 dB") +
            _m4a_freeform("iTunNORM", " 0000 ..."))
    mvhd = bytes(12) + struct.pack(">II", 44100, 44100) + bytes(80)
    moov = _mp4_box(b"moov", _mp4_box(b"mvhd", mvhd) +
                    _mp4_box(b"udta", _mp4_box(b"meta", bytes(4) + _mp4_box(b"ilst", ilst))))
    write(lib, "RG/Album/04 - M4a.m4a",
          _mp4_box(b"ftyp", b"M4A " + bytes(4) + b"M4A mp42isom") + moov + _mp4_box(b"mdat", bytes(64)))


def populate(name: str, lib: Path):
    F = lambda n, meta=None, fmt="flac": write(lib, n, audio_bytes(fmt, meta))
    if name == "replaygain_tags":
        populate_replaygain(lib)
    elif name == "flac_full_tags":
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

def rescan_check() -> int:
    """重掃已 commit 的 cases/*/lib，輸出必須與 expected.json byte-identical。
    不跑 ffmpeg、純確定性 —— CI 用（規格 ↔ fixtures 防飄移）。"""
    names = build_cases()
    bad = []
    for name in names:
        result = scan_tree(CASES / name / "lib")
        for t in result["tracks"]:
            t.pop("_compilation")
        for e in result["errors"]:
            e["message"] = ""
        expected_path = CASES / name / "expected.json"
        actual = canonical(result)
        if not expected_path.exists() or \
                expected_path.read_text(encoding="utf-8") != actual:
            bad.append(name)
    if bad:
        print(f"DRIFT: {len(bad)}/{len(names)} cases differ from expected.json: "
              + ", ".join(bad))
        return 1
    print(f"OK: {len(names)} cases byte-identical to expected.json")
    return 0

def update_expected() -> int:
    """重掃已 commit 的 cases/*/lib，只改寫 expected.json（不跑 ffmpeg、不動 lib/）。
    規格升級（如 §1.7 時長）換版 fixtures 用。"""
    names = build_cases()
    for name in names:
        result = scan_tree(CASES / name / "lib")
        for t in result["tracks"]:
            t.pop("_compilation")
        for e in result["errors"]:
            e["message"] = ""
        (CASES / name / "expected.json").write_text(canonical(result), encoding="utf-8")
    print(f"OK: {len(names)} expected.json updated from committed lib trees")
    return 0

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
    if len(sys.argv) == 3 and sys.argv[1] == "--case":
        name = sys.argv[2]
        assert name in build_cases(), name
        case = CASES / name
        if case.exists():
            shutil.rmtree(case)
        lib = case / "lib"
        lib.mkdir(parents=True)
        populate(name, lib)
        result = scan_tree(lib)
        for t in result["tracks"]:
            t.pop("_compilation")
        for e in result["errors"]:
            e["message"] = ""
        (case / "expected.json").write_text(canonical(result), encoding="utf-8")
        if name == "replaygain_tags":
            tr = {t["path"]: t for t in result["tracks"]}
            assert (tr["RG/Album/01 - Flac.flac"]["replayGainTrackMb"], tr["RG/Album/01 - Flac.flac"]["replayGainAlbumMb"]) == (-654, 210)
            assert (tr["RG/Album/02 - Flac Odd.flac"]["replayGainTrackMb"], tr["RG/Album/02 - Flac Odd.flac"]["replayGainAlbumMb"]) == (None, 356)
            assert (tr["RG/Album/03 - Mp3.mp3"]["replayGainTrackMb"], tr["RG/Album/03 - Mp3.mp3"]["replayGainAlbumMb"]) == (-725, 50)
            assert tr["RG/Album/03 - Mp3.mp3"]["title"] == "Gainy"
            assert (tr["RG/Album/04 - M4a.m4a"]["replayGainTrackMb"], tr["RG/Album/04 - M4a.m4a"]["replayGainAlbumMb"]) == (-300, None)
            assert tr["RG/Album/04 - M4a.m4a"]["title"] == "Boxed" and tr["RG/Album/04 - M4a.m4a"]["durationMs"] == 1000
            assert parse_gain_mb("-6.545") == -654 and parse_gain_mb("  +3  ") == 300 and parse_gain_mb(".5") is None
        print(f"OK: case {name} regenerated")
        sys.exit(0)
    if sys.argv[1:] == ["--rescan-check"]:
        sys.exit(rescan_check())
    if sys.argv[1:] == ["--update-expected"]:
        sys.exit(update_expected())
    main()
