#!/usr/bin/env python3
"""
Crate Dropbox provider 契約 fixtures 產生器（兼 Python 參考實作）

- provider.md §9：DropboxProvider（list_folder / continue / get_latest_cursor / download+Range；
  節點表 key=path_lower；content_hash = rev；reset；§9.5 錯誤對應套 §2.1）
- FakeDropbox：HTTP 語意層的 in-memory Dropbox（三實作各自複製同一份語意；本檔為參考）
- 產出 dropbox_cases/<name>/script.json + expected.json（每步 = {provider 統計, SyncReport}）

重跑：python3 dropbox_generate.py          （重寫 script + expected）
驗證：python3 dropbox_generate.py --check  （重放比對 expected；可進 CI）
"""
import hashlib, json, sys
from datetime import datetime, timezone
from pathlib import Path

from generate import canonical, ByteSource
from sync_generate import ASSETS, SyncEngine, ProviderError, NotFoundError
from gdrive_generate import (AuthError, TransientError, HttpError, TransportError,
                             TRANSIENT_DELAYS, MAX_TRANSIENT_RETRIES, parse_iso_ms)

HERE = Path(__file__).parent
CASES = HERE / "dropbox_cases"

API = "https://api.dropboxapi.com/2"
CONTENT = "https://content.dropboxapi.com/2"
LIMIT = 2000


def content_hash(data: bytes) -> str:
    """Dropbox content_hash：4MB 分塊 SHA-256 串接後再 SHA-256。"""
    h = hashlib.sha256()
    for i in range(0, max(len(data), 1), 4 * 1024 * 1024):
        h.update(hashlib.sha256(data[i:i + 4 * 1024 * 1024]).digest())
    return h.hexdigest()


def iso_s(ms: int) -> str:
    return datetime.fromtimestamp(ms // 1000, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# ---------------------------------------------------------------- FakeDropbox（HTTP 語意層）

class FakeDropbox:
    """in-memory Dropbox。seq 遞增；cursor = "c<seq>"（= 已看到 seq 之前的變更）。"""

    def __init__(self, max_page: int = LIMIT):
        self.max_page = max_page
        self.files: dict[str, dict] = {}    # path_lower -> {display, id, data, hash, modifiedAt}
        self.folders: dict[str, str] = {}   # path_lower -> display
        self.log: list[tuple[int, str]] = []
        self.seq = 0
        self.min_cursor = 1
        self.next_id = 1
        self.forced: list[str] = []
        self.skip = 0
        self.token_n = 1
        self.token_valid = True
        self.requests = 0

    def current_token(self) -> str:
        return f"tok-{self.token_n}"

    def issue_token(self) -> str:
        self.token_n += 1
        self.token_valid = True
        return self.current_token()

    # ---- ops
    def _bump(self, pl: str):
        self.seq += 1
        self.log.append((self.seq, pl))

    def mkdir(self, path: str):
        self.folders[path.lower()] = path
        self._bump(path.lower())

    def put(self, path: str, data: bytes, mtime: int):
        pl = path.lower()
        old = self.files.get(pl)
        fid = old["id"] if old else f"id:f{self.next_id}"
        if not old:
            self.next_id += 1
        self.files[pl] = dict(display=path, id=fid, data=data, hash=content_hash(data),
                              modifiedAt=mtime * 1000)
        self._bump(pl)

    def touch(self, path: str, mtime: int):
        self.files[path.lower()]["modifiedAt"] = mtime * 1000
        self._bump(path.lower())

    def rename(self, src: str, dst: str):
        sl, dl = src.lower(), dst.lower()
        if sl in self.files:
            e = self.files.pop(sl)
            e["display"] = dst
            self.files[dl] = e
            self._bump(sl)
            self._bump(dl)
            return
        # 資料夾：deleted(舊) + folder(新) + 子項逐一 file/folder
        self.folders.pop(sl)
        self.folders[dl] = dst
        self._bump(sl)
        self._bump(dl)
        for pl in sorted(k for k in list(self.folders) + list(self.files) if k.startswith(sl + "/")):
            rest = pl[len(sl):]
            if pl in self.folders:
                disp = self.folders.pop(pl)
                self.folders[dl + rest] = dst + disp[len(src):]
            else:
                e = self.files.pop(pl)
                e["display"] = dst + e["display"][len(src):]
                self.files[dl + rest] = e
            self._bump(dl + rest)

    def delete(self, path: str):
        pl = path.lower()
        if pl in self.files:
            self.files.pop(pl)
        else:
            self.folders.pop(pl)
            for k in [k for k in list(self.folders) + list(self.files) if k.startswith(pl + "/")]:
                self.folders.pop(k, None)
                self.files.pop(k, None)
        self._bump(pl)  # 資料夾只回一筆 deleted

    def invalidate_cursor(self):
        self.seq += 1
        self.min_cursor = self.seq + 1

    def expire_token(self):
        self.token_valid = False

    def fail(self, kind: str, count: int, skip: int = 0):
        self.forced.extend([kind] * count)
        self.skip = skip

    # ---- HTTP
    def _entry(self, pl: str) -> dict:
        if pl in self.files:
            f = self.files[pl]
            return {".tag": "file", "name": f["display"].rsplit("/", 1)[-1], "path_lower": pl,
                    "path_display": f["display"], "id": f["id"], "rev": f["hash"][:9],
                    "size": len(f["data"]), "content_hash": f["hash"],
                    "server_modified": iso_s(f["modifiedAt"]), "client_modified": iso_s(f["modifiedAt"])}
        if pl in self.folders:
            d = self.folders[pl]
            return {".tag": "folder", "name": d.rsplit("/", 1)[-1], "path_lower": pl,
                    "path_display": d, "id": "id:d" + pl}
        return {".tag": "deleted", "name": pl.rsplit("/", 1)[-1], "path_lower": pl, "path_display": pl}

    def _under(self, root_lower: str, pl: str) -> bool:
        return root_lower == "" or pl == root_lower or pl.startswith(root_lower + "/")

    def handle(self, method: str, url: str, headers: dict, body: bytes) -> tuple[int, bytes]:
        self.requests += 1
        if self.forced:
            if self.skip > 0:
                self.skip -= 1
            else:
                kind = self.forced.pop(0)
                if kind == "transient":
                    return 503, b'{"error_summary":"internal"}'
                if kind == "ratelimit":
                    return 429, b'{"error_summary":"too_many_requests/..","error":{"reason":{".tag":"too_many_requests"}}}'
                if kind == "notfound":
                    return 409, b'{"error_summary":"path/not_found/..","error":{".tag":"path","path":{".tag":"not_found"}}}'
                if kind == "offline":
                    raise TransportError("offline")
                raise ValueError(kind)
        if headers.get("Authorization") != f"Bearer {self.current_token()}" or not self.token_valid:
            return 401, b'{"error_summary":"expired_access_token/..","error":{".tag":"expired_access_token"}}'
        if url == f"{API}/files/get_metadata":
            pl = json.loads(body)["path"].lower()
            if pl in self.folders or pl in self.files:
                return 200, json.dumps(self._entry(pl)).encode()
            return 409, b'{"error_summary":"path/not_found/..","error":{".tag":"path","path":{".tag":"not_found"}}}'
        if url == f"{API}/files/list_folder/get_latest_cursor":
            arg = json.loads(body)
            return 200, json.dumps({"cursor": f"c{self.seq + 1}:{arg['path'].lower()}"}).encode()
        if url == f"{API}/files/list_folder":
            arg = json.loads(body)
            root_lower = arg["path"].lower()
            if root_lower and root_lower not in self.folders:
                return 409, b'{"error_summary":"path/not_found/..","error":{".tag":"path","path":{".tag":"not_found"}}}'
            cap = min(int(arg.get("limit", LIMIT)), self.max_page)
            keys = sorted(k for k in list(self.folders) + list(self.files)
                          if self._under(root_lower, k) and k != root_lower)
            page, rest = keys[:cap], keys[cap:]
            cursor = (f"l{cap}:{root_lower}:{rest[0]}" if rest else f"c{self.seq + 1}:{root_lower}")
            return 200, json.dumps({"entries": [self._entry(k) for k in page],
                                    "cursor": cursor, "has_more": bool(rest)}).encode()
        if url == f"{API}/files/list_folder/continue":
            cursor = json.loads(body)["cursor"]
            if cursor.startswith("l"):  # 全量列舉續頁
                cap_s, root_lower, start = cursor[1:].split(":", 2)
                cap = int(cap_s)
                keys = sorted(k for k in list(self.folders) + list(self.files)
                              if self._under(root_lower, k) and k != root_lower and k >= start)
                page, rest = keys[:cap], keys[cap:]
                nxt = (f"l{cap}:{root_lower}:{rest[0]}" if rest else f"c{self.seq + 1}:{root_lower}")
                return 200, json.dumps({"entries": [self._entry(k) for k in page],
                                        "cursor": nxt, "has_more": bool(rest)}).encode()
            if not cursor.startswith("c"):
                return 400, b'{"error_summary":"invalid cursor"}'
            t_s, root_lower = cursor[1:].split(":", 1)
            t = int(t_s)
            if t < self.min_cursor or t > self.seq + 1:
                return 409, b'{"error_summary":"reset/..","error":{".tag":"reset"}}'
            entries = [(s, pl) for s, pl in self.log if s >= t and self._under(root_lower, pl)]
            page, rest = entries[:self.max_page], entries[self.max_page:]
            nxt = f"c{rest[0][0]}:{root_lower}" if rest else f"c{self.seq + 1}:{root_lower}"
            return 200, json.dumps({"entries": [self._entry(pl) for _, pl in page],
                                    "cursor": nxt, "has_more": bool(rest)}).encode()
        if url == f"{CONTENT}/files/download":
            arg = json.loads(headers.get("Dropbox-API-Arg", "{}"))
            ref = arg.get("path", "")
            f = next((f for f in self.files.values() if f["id"] == ref), None) \
                if ref.startswith("id:") else self.files.get(ref.lower())
            if f is None:
                return 409, b'{"error_summary":"path/not_found/..","error":{".tag":"path","path":{".tag":"not_found"}}}'
            data = f["data"]
            rng = headers.get("Range")
            if rng and rng.startswith("bytes="):
                a, b = rng[6:].split("-", 1)
                a = int(a)
                b = int(b) if b else len(data) - 1
                return 206, data[a:b + 1]
            return 200, data
        return 404, b'{"error_summary":"unknown endpoint"}'


# ---------------------------------------------------------------- DropboxProvider（參考實作）

class DropboxProvider:
    """provider.md §9。transport(method, url, headers, body) -> (status, body)。"""

    def __init__(self, root: str, transport, token_source, sleep):
        self.root = root                   # 使用者輸入（路徑 / id: / ""）
        self.transport = transport
        self.token_source = token_source
        self.sleep = sleep
        self.root_lower: str | None = None
        self.root_display: str | None = None
        self.nodes: dict[str, dict] = {}   # path_lower -> {display, id, size, hash, modifiedAt}
        self.cursor: str | None = None
        self.path_to_id: dict[str, str] = {}
        self.reauths = 0
        self.sleeps: list[int] = []
        self.reset = False

    def begin_round(self):
        self.reauths, self.sleeps, self.reset = 0, [], False

    # ---- HTTP + §2.1
    def _call(self, url: str, arg: dict | None = None, extra_headers: dict | None = None) -> tuple[int, bytes]:
        transient = 0
        reauth_used = False
        token = self.token_source.token()
        while True:
            headers = {"Authorization": f"Bearer {token}"}
            body = b""
            if extra_headers:
                headers.update(extra_headers)
            else:
                headers["Content-Type"] = "application/json"
                body = json.dumps(arg or {}).encode()
            try:
                status, rbody = self.transport("POST", url, headers, body)
            except TransportError:
                status, rbody = 0, b""
            if 200 <= status < 300:
                return status, rbody
            if status == 401:
                if reauth_used:
                    raise AuthError()
                reauth_used = True
                self.reauths += 1
                token = self.token_source.refresh()
                continue
            if status == 0 or status == 429 or status >= 500:
                if transient >= MAX_TRANSIENT_RETRIES:
                    raise TransientError()
                self.sleep(TRANSIENT_DELAYS[transient])
                self.sleeps.append(TRANSIENT_DELAYS[transient])
                transient += 1
                continue
            if status == 409 and b"not_found" in rbody:
                raise NotFoundError()
            if status == 409 and b"reset" in rbody:
                raise CursorReset()
            raise HttpError(status)

    def _rpc(self, endpoint: str, arg: dict) -> dict:
        return json.loads(self._call(f"{API}/{endpoint}", arg)[1])

    # ---- 節點表
    def _list_arg(self) -> dict:
        return {"path": self.root_lower, "recursive": True, "include_deleted": False, "limit": LIMIT}

    def _resolve_root(self):
        if self.root_lower is not None:
            return
        if self.root == "":
            self.root_lower, self.root_display = "", ""
            return
        m = self._rpc("files/get_metadata", {"path": self.root})
        self.root_lower, self.root_display = m["path_lower"], m["path_display"]

    def _apply(self, entries: list[dict]):
        for e in entries:
            tag = e.get(".tag")
            pl = e["path_lower"]
            if tag == "file":
                self.nodes[pl] = dict(display=e["path_display"], id=e["id"], size=int(e.get("size", 0)),
                                      hash=e.get("content_hash") or e.get("rev", ""),
                                      modifiedAt=parse_iso_ms(e["server_modified"]))
            elif tag == "deleted":
                self.nodes.pop(pl, None)
                for k in [k for k in self.nodes if k.startswith(pl + "/")]:
                    self.nodes.pop(k)

    def _full(self):
        self._resolve_root()
        start = self._rpc("files/list_folder/get_latest_cursor", self._list_arg())["cursor"]
        self.nodes = {}
        r = self._rpc("files/list_folder", self._list_arg())
        self._apply(r["entries"])
        while r.get("has_more"):
            r = self._rpc("files/list_folder/continue", {"cursor": r["cursor"]})
            self._apply(r["entries"])
        self.cursor = start

    def _delta(self):
        cursor = self.cursor
        while True:
            r = self._rpc("files/list_folder/continue", {"cursor": cursor})
            self._apply(r["entries"])
            cursor = r["cursor"]
            if not r.get("has_more"):
                break
        self.cursor = cursor

    def snapshot(self) -> dict[str, str]:
        if self.cursor is None:
            self._full()
        else:
            try:
                self._delta()
            except CursorReset:
                self.reset = True
                self.cursor = None
                self._full()
        return self._paths()

    def _paths(self) -> dict[str, str]:
        snap: dict[str, str] = {}
        self.path_to_id = {}
        prefix = self.root_display + "/" if self.root_display else "/"
        for pl in sorted(self.nodes):
            n = self.nodes[pl]
            if not n["display"].startswith(prefix):
                continue
            path = n["display"][len(prefix):]
            snap[path] = n["hash"] if n["hash"] else f"{n['size']}:{n['modifiedAt']}"
            self.path_to_id[path] = n["id"]
        return snap

    def open(self, path: str) -> ByteSource | None:
        fid = self.path_to_id.get(path)
        if fid is None:
            return None
        pl = next(k for k, n in self.nodes.items() if n["id"] == fid)
        return _DropboxSource(self, fid, self.nodes[pl]["size"])


class CursorReset(Exception):
    pass


class _DropboxSource(ByteSource):
    def __init__(self, provider: DropboxProvider, fid: str, size: int):
        self.provider, self.fid, self.size = provider, fid, size

    def read(self, offset: int, length: int) -> bytes:
        if length <= 0:
            return b""
        status, body = self.provider._call(
            f"{CONTENT}/files/download", None,
            {"Dropbox-API-Arg": json.dumps({"path": self.fid}),
             "Range": f"bytes={offset}-{offset + length - 1}"})
        return body if status == 206 else body[offset:offset + length]


# ---------------------------------------------------------------- driver

ROOT = "/Music"


class TokenSource:
    def __init__(self, d: FakeDropbox):
        self.d = d

    def token(self) -> str:
        return self.d.current_token()

    def refresh(self) -> str:
        return self.d.issue_token()


def _data(op: dict) -> bytes:
    return (ASSETS / op["asset"]).read_bytes() if "asset" in op else op["text"].encode("utf-8")


def apply_op(d: FakeDropbox, op: dict, delete_after: list[str]):
    k = op["op"]
    if k == "mkdir":
        d.mkdir(op["path"])
    elif k == "put":
        d.put(op["path"], _data(op), op["mtime"])
    elif k == "rename":
        d.rename(op["from"], op["to"])
    elif k == "delete":
        d.delete(op["path"])
    elif k == "touch":
        d.touch(op["path"], op["mtime"])
    elif k == "invalidate_cursor":
        d.invalidate_cursor()
    elif k == "expire_token":
        d.expire_token()
    elif k == "fail":
        d.fail(op["kind"], op["count"], op.get("skip", 0))
    elif k == "delete_after_delta":
        delete_after.append(op["path"])
    else:
        raise ValueError(k)


def run_case(case_dir: Path) -> list[dict]:
    script = json.loads((case_dir / "script.json").read_text(encoding="utf-8"))
    d = FakeDropbox(max_page=script.get("maxPage", LIMIT))
    provider = DropboxProvider(script.get("root", ROOT), d.handle, TokenSource(d), sleep=lambda ms: None)
    engine = SyncEngine(provider)
    out = []
    for step in script["steps"]:
        delete_after: list[str] = []
        for op in step["ops"]:
            apply_op(d, op, delete_after)
        d.requests = 0
        provider.begin_round()
        error = None
        try:
            report = engine.sync(after_delta=lambda ds=delete_after: [d.delete(p) for p in ds])
        except AuthError:
            error, report = "auth", None
        except TransientError:
            error, report = "transient", None
        out.append({
            "provider": {
                "error": error,
                "reauths": provider.reauths,
                "requests": d.requests,
                "reset": provider.reset,
                "sleeps": list(provider.sleeps),
                "unscanned": list(engine.unscanned) if error is None else [],
            },
            "report": report,
        })
    return out


# ---------------------------------------------------------------- cases

def build_scripts() -> dict[str, dict]:
    def lib():
        return [
            {"op": "mkdir", "path": "/Music"},
            {"op": "mkdir", "path": "/Music/Aurora"},
            {"op": "mkdir", "path": "/Music/Aurora/Northern Lights"},
            {"op": "put", "path": "/Music/Aurora/Northern Lights/01 - Rise.flac", "asset": "flac_a", "mtime": 1700000100},
            {"op": "put", "path": "/Music/Aurora/Northern Lights/02 - Drift.flac", "asset": "flac_b", "mtime": 1700000101},
            {"op": "put", "path": "/Music/Aurora/Northern Lights/cover.jpg", "text": "not-a-real-jpg", "mtime": 1700000102},
            {"op": "mkdir", "path": "/Music/Various Artists"},
            {"op": "mkdir", "path": "/Music/Various Artists/Dream Mixtape"},
            {"op": "put", "path": "/Music/Various Artists/Dream Mixtape/07 - Unknown.flac", "asset": "flac_notags", "mtime": 1700000103},
        ]

    return {
        "dropbox_initial_scan": {"steps": [
            {"ops": lib() + [
                {"op": "mkdir", "path": "/Other"},
                {"op": "put", "path": "/Other/03 - Elsewhere.flac", "asset": "flac_a", "mtime": 1700000105},
                {"op": "put", "path": "/Musician.flac", "asset": "flac_a", "mtime": 1700000106},  # 前綴相似但不在 root 內
            ]},
            {"ops": []},
        ]},
        "dropbox_root_case_insensitive": {"root": "/music", "steps": [  # root 以不同大小寫給入 → get_metadata 解析 path_display
            {"ops": lib()},
            {"ops": []},
        ]},
        "dropbox_paging": {"maxPage": 2, "steps": [
            {"ops": lib()},
            {"ops": [
                {"op": "put", "path": "/Music/Various Artists/Dream Mixtape/02 - Ninjya.mp3", "asset": "mp3_tags", "mtime": 1700000200},
                {"op": "touch", "path": "/Music/Aurora/Northern Lights/01 - Rise.flac", "mtime": 1700000201},
                {"op": "touch", "path": "/Music/Aurora/Northern Lights/02 - Drift.flac", "mtime": 1700000202},
            ]},
            {"ops": []},
        ]},
        "dropbox_changes": {"steps": [
            {"ops": lib()},
            {"ops": [{"op": "put", "path": "/Music/Aurora/Northern Lights/01 - Rise.flac", "asset": "flac_b", "mtime": 1700000300}]},
            {"ops": [{"op": "rename", "from": "/Music/Aurora/Northern Lights/02 - Drift.flac",
                      "to": "/Music/Aurora/Northern Lights/02 - Drifted.flac"}]},
            {"ops": [{"op": "touch", "path": "/Music/Various Artists/Dream Mixtape/07 - Unknown.flac", "mtime": 1700000400}]},
            {"ops": [  # 資料夾從 root 外搬進來 → 子樹進庫
                {"op": "mkdir", "path": "/Kyary"},
                {"op": "mkdir", "path": "/Kyary/Jelly"},
                {"op": "put", "path": "/Kyary/Jelly/02 - Ninjya.mp3", "asset": "mp3_tags", "mtime": 1700000500},
                {"op": "rename", "from": "/Kyary", "to": "/Music/Kyary"},
            ]},
            {"ops": [{"op": "rename", "from": "/Music/Kyary", "to": "/Music/Kyary Pamyu"}]},  # 資料夾改名 → 子樹 removed+added
            {"ops": [{"op": "delete", "path": "/Music/Kyary Pamyu"}]},  # 刪資料夾只一筆 deleted → 子樹全 removed
            {"ops": [
                {"op": "delete", "path": "/Music/Various Artists/Dream Mixtape/07 - Unknown.flac"},
                {"op": "put", "path": "/Music/best.m3u8", "mtime": 1700000600,
                 "text": "#EXTM3U\n#EXTINF:213.5,Rise\nAurora/Northern Lights/01 - Rise.flac\nAurora/Northern Lights/02 - Drifted.flac\n"},
            ]},
            {"ops": [{"op": "delete", "path": "/Music/best.m3u8"}]},
        ]},
        "dropbox_cursor_reset": {"steps": [
            {"ops": lib()},
            {"ops": [
                {"op": "put", "path": "/Music/Various Artists/Dream Mixtape/02 - Ninjya.mp3", "asset": "mp3_tags", "mtime": 1700000700},
                {"op": "invalidate_cursor"},
            ]},
            {"ops": []},
        ]},
        "dropbox_retry": {"steps": [
            {"ops": lib()},
            {"ops": [{"op": "expire_token"}]},
            {"ops": [
                {"op": "fail", "kind": "transient", "count": 2},
                {"op": "fail", "kind": "ratelimit", "count": 1},
                {"op": "put", "path": "/Music/Various Artists/Dream Mixtape/02 - Ninjya.mp3", "asset": "mp3_tags", "mtime": 1700000800},
            ]},
            {"ops": [
                {"op": "fail", "kind": "offline", "count": 6},
                {"op": "put", "path": "/Music/Various Artists/Dream Mixtape/03 - North.m4a", "asset": "m4a_tags", "mtime": 1700000801},
            ]},
            {"ops": []},
        ]},
        "dropbox_scan_resume": {"steps": [
            {"ops": [{"op": "mkdir", "path": "/Music"}, {"op": "mkdir", "path": "/Music/Aurora"},
                     {"op": "mkdir", "path": "/Music/Aurora/Northern Lights"}]},
            {"ops": [
                {"op": "put", "path": "/Music/Aurora/Northern Lights/01 - Rise.flac", "asset": "flac_a", "mtime": 1700000900},
                {"op": "put", "path": "/Music/Aurora/Northern Lights/02 - Drift.flac", "asset": "flac_b", "mtime": 1700000901},
                {"op": "put", "path": "/Music/Aurora/Northern Lights/03 - Unknown.flac", "asset": "flac_notags", "mtime": 1700000902},
                {"op": "fail", "kind": "transient", "count": 6, "skip": 2},
            ]},
            {"ops": []},
            {"ops": [
                {"op": "put", "path": "/Music/Aurora/Northern Lights/04 - Ghost.flac", "asset": "flac_b", "mtime": 1700000903},
                {"op": "delete_after_delta", "path": "/Music/Aurora/Northern Lights/04 - Ghost.flac"},
            ]},
            {"ops": []},
        ]},
        "dropbox_windowed_scan": {"root": "", "steps": [  # root = 整個 Dropbox
            {"ops": [
                {"op": "mkdir", "path": "/Big"},
                {"op": "put", "path": "/Big/01 - Tail Moov.m4a", "asset": "m4a_tail_big", "mtime": 1700001100},
                {"op": "put", "path": "/Big/02 - Big Pic.flac", "asset": "flac_bigpic", "mtime": 1700001101},
                {"op": "put", "path": "/Big/03 - Big Apic.mp3", "asset": "mp3_bigapic", "mtime": 1700001102},
            ]},
            {"ops": []},
        ]},
    }


def main():
    if CASES.exists():
        import shutil
        shutil.rmtree(CASES)
    scripts = build_scripts()
    for name, script in scripts.items():
        case = CASES / name
        case.mkdir(parents=True)
        (case / "script.json").write_text(
            json.dumps(script, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        (case / "expected.json").write_text(canonical(run_case(case)), encoding="utf-8")

    def step(name, i):
        return json.loads((CASES / name / "expected.json").read_text())[i]

    s = step("dropbox_initial_scan", 0)
    assert sorted(t["path"] for t in s["report"]["index"]["tracks"]) == [
        "Aurora/Northern Lights/01 - Rise.flac", "Aurora/Northern Lights/02 - Drift.flac",
        "Various Artists/Dream Mixtape/07 - Unknown.flac"]
    assert s["provider"]["requests"] == 1 + 1 + 1 + 3, s["provider"]  # get_metadata + cursor + list + 3 下載
    s = step("dropbox_initial_scan", 1)
    assert s["report"]["changes"] == [] and s["provider"]["requests"] == 1
    s = step("dropbox_root_case_insensitive", 0)
    assert len(s["report"]["index"]["tracks"]) == 3 and s["report"]["index"]["tracks"][0]["path"].startswith("Aurora/")
    s = step("dropbox_paging", 0)
    assert s["provider"]["requests"] == 1 + 1 + 4 + 3, s["provider"]  # 8 entries / 2 per page
    s = step("dropbox_paging", 1)
    assert s["provider"]["requests"] == 2 + 1, s["provider"]
    assert [c["kind"] for c in s["report"]["changes"]] == ["added"]
    s = step("dropbox_changes", 1)
    assert [c["kind"] for c in s["report"]["changes"]] == ["modified"]
    s = step("dropbox_changes", 2)
    kinds = sorted((c["path"], c["kind"]) for c in s["report"]["changes"])
    assert kinds == [("Aurora/Northern Lights/02 - Drift.flac", "removed"),
                     ("Aurora/Northern Lights/02 - Drifted.flac", "added")], kinds
    assert len({c["rev"] for c in s["report"]["changes"]}) == 1
    s = step("dropbox_changes", 3)
    assert s["report"]["changes"] == []
    s = step("dropbox_changes", 4)
    assert [c["path"] for c in s["report"]["changes"]] == ["Kyary/Jelly/02 - Ninjya.mp3"]
    s = step("dropbox_changes", 5)
    kinds = sorted((c["path"], c["kind"]) for c in s["report"]["changes"])
    assert kinds == [("Kyary Pamyu/Jelly/02 - Ninjya.mp3", "added"), ("Kyary/Jelly/02 - Ninjya.mp3", "removed")], kinds
    s = step("dropbox_changes", 6)
    assert [(c["path"], c["kind"]) for c in s["report"]["changes"]] == [("Kyary Pamyu/Jelly/02 - Ninjya.mp3", "removed")]
    s = step("dropbox_changes", 7)
    assert [it["missing"] for it in s["report"]["index"]["playlists"][0]["items"]] == [False, False]
    s = step("dropbox_cursor_reset", 1)
    assert s["provider"]["reset"] is True and s["provider"]["requests"] == 1 + 1 + 1 + 1, s["provider"]
    assert [c["kind"] for c in s["report"]["changes"]] == ["added"]
    s = step("dropbox_retry", 1)
    assert s["provider"]["reauths"] == 1 and s["provider"]["error"] is None
    s = step("dropbox_retry", 2)
    assert s["provider"]["sleeps"] == [1000, 2000, 4000] and s["provider"]["requests"] == 5, s["provider"]
    s = step("dropbox_retry", 3)
    assert s["provider"]["error"] == "transient" and s["report"] is None
    s = step("dropbox_retry", 4)
    assert [c["path"] for c in s["report"]["changes"]] == ["Various Artists/Dream Mixtape/03 - North.m4a"]
    s = step("dropbox_scan_resume", 1)
    assert s["provider"]["unscanned"] == ["Aurora/Northern Lights/02 - Drift.flac",
                                          "Aurora/Northern Lights/03 - Unknown.flac"]
    s = step("dropbox_scan_resume", 2)
    assert len(s["report"]["scanned"]) == 2 and s["provider"]["unscanned"] == []
    s = step("dropbox_scan_resume", 3)
    assert s["report"]["scanned"] == [] and [c["kind"] for c in s["report"]["changes"]] == ["added"]
    s = step("dropbox_scan_resume", 4)
    assert [c["kind"] for c in s["report"]["changes"]] == ["removed"]
    s = step("dropbox_windowed_scan", 0)
    assert s["provider"]["requests"] == 1 + 1 + 2 + 2 + 2, s["provider"]  # root="" 免 get_metadata
    tr = {t["path"]: t for t in s["report"]["index"]["tracks"]}
    assert tr["Big/01 - Tail Moov.m4a"]["durationMs"] == 10000 and tr["Big/03 - Big Apic.mp3"]["title"] == "Big Cover"
    assert content_hash(b"") == hashlib.sha256(hashlib.sha256(b"").digest()).hexdigest()
    print(f"OK: {len(scripts)} dropbox cases generated, all sanity asserts passed")


def check() -> int:
    bad = []
    for case in sorted(CASES.iterdir()):
        if not case.is_dir():
            continue
        actual = canonical(run_case(case))
        expected_path = case / "expected.json"
        if not expected_path.exists() or expected_path.read_text(encoding="utf-8") != actual:
            bad.append(case.name)
    if bad:
        print(f"DRIFT: {len(bad)} dropbox case(s) differ: {', '.join(bad)}")
        return 1
    print("OK: all dropbox cases byte-identical to expected.json")
    return 0


if __name__ == "__main__":
    # 未知參數一律退出，**不**掉進會重寫 fixtures 的 main()（同 generate.py）。
    args = sys.argv[1:]
    if args == ["--check"]:
        sys.exit(check())
    elif args:
        sys.exit(f"未知參數：{' '.join(args)}\n"
                 f"用法：python3 {__file__.split('/')[-1]} [--check]"
                 f"（無參數 = 重新產生，會覆寫 fixtures）")
    main()
