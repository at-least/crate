#!/usr/bin/env python3
"""
Crate GDrive provider 契約 fixtures 產生器（兼 Python 參考實作）

- provider.md §8：GDriveProvider（files.list / changes / files.get?alt=media；節點表 → path；md5 = rev；
  reset；§8.5 錯誤對應套 §2.1 RetryPolicy）
- sync-rules.md §3.2-8：續掃語意（unscanned）
- FakeDrive：HTTP 語意層的 in-memory Drive（三實作各自複製同一份語意；本檔為參考）
- 產出 gdrive_cases/<name>/script.json + expected.json（每步 = {provider 統計, SyncReport}）

重跑：python3 gdrive_generate.py          （重寫 script + expected；資產池 committed，不跑 ffmpeg）
驗證：python3 gdrive_generate.py --check  （重放比對 expected；可進 CI）
"""
import hashlib, json, sys
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlsplit, parse_qs

from generate import canonical
from generate import ByteSource
from sync_generate import ASSETS, SyncEngine, ProviderError, NotFoundError

HERE = Path(__file__).parent
CASES = HERE / "gdrive_cases"

BASE = "https://www.googleapis.com/drive/v3"
FOLDER = "application/vnd.google-apps.folder"
TRANSIENT_DELAYS = [1000, 2000, 4000, 8000, 16000]
MAX_TRANSIENT_RETRIES = 5
PAGE_SIZE = 1000

FILE_FIELDS = "id,name,mimeType,parents,size,md5Checksum,modifiedTime"
LIST_FIELDS = f"nextPageToken,files({FILE_FIELDS})"
CHANGE_FIELDS = f"nextPageToken,newStartPageToken,changes(fileId,removed,file({FILE_FIELDS},trashed))"


def iso_ms(ms: int) -> str:
    return datetime.fromtimestamp(ms / 1000, timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.") \
        + f"{ms % 1000:03d}Z"


def parse_iso_ms(s: str) -> int:
    """RFC3339（Drive 固定 UTC `Z`；小數秒可有可無）→ ms。"""
    if s.endswith("Z"):
        s = s[:-1]
    if "." in s:
        head, frac = s.split(".", 1)
        frac = (frac + "000")[:3]
    else:
        head, frac = s, "000"
    dt = datetime.strptime(head, "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc)
    return int(dt.timestamp()) * 1000 + int(frac)


# ---------------------------------------------------------------- errors

class AuthError(ProviderError):
    pass


class TransientError(ProviderError):
    pass


class HttpError(ProviderError):
    def __init__(self, status: int):
        super().__init__(f"http {status}")
        self.status = status


class TransportError(Exception):
    """傳輸層失敗（連不上）→ transient。"""


# ---------------------------------------------------------------- FakeDrive（HTTP 語意層）

class FakeDrive:
    """in-memory Drive。token 語意：seq 遞增；startPageToken = seq+1；changes(pageToken=T) = seq >= T。"""

    def __init__(self, max_page: int = PAGE_SIZE):
        self.max_page = max_page
        self.nodes: dict[str, dict] = {}   # id -> {name,mimeType,parent,trashed,size,md5,modifiedAt,data}
        self.log: list[tuple[int, str]] = []
        self.seq = 0
        self.min_token = 1
        self.forced: list[str] = []         # 強制回應佇列（transient/ratelimit/notfound/offline）
        self.skip = 0                       # 強制回應前先放行的請求數
        self.token_n = 1
        self.token_valid = True
        self.requests = 0

    # ---- token source 面
    def current_token(self) -> str:
        return f"tok-{self.token_n}"

    def issue_token(self) -> str:
        self.token_n += 1
        self.token_valid = True
        return self.current_token()

    # ---- script ops
    def _bump(self, fid: str):
        self.seq += 1
        self.log.append((self.seq, fid))

    def mkdir(self, fid: str, name: str, parent: str, mtime: int = 1700000000):
        self.nodes[fid] = dict(name=name, mimeType=FOLDER, parent=parent, trashed=False,
                               size=None, md5=None, modifiedAt=mtime * 1000, data=b"")
        self._bump(fid)

    def put(self, fid: str, name: str, parent: str, data: bytes, mtime: int,
            mime: str = "application/octet-stream", md5: bool = True):
        self.nodes[fid] = dict(name=name, mimeType=mime, parent=parent, trashed=False,
                               size=len(data), md5=hashlib.md5(data).hexdigest() if md5 else None,
                               modifiedAt=mtime * 1000, data=data)
        self._bump(fid)

    def update(self, fid: str, data: bytes, mtime: int):
        n = self.nodes[fid]
        n.update(size=len(data), md5=hashlib.md5(data).hexdigest(), modifiedAt=mtime * 1000, data=data)
        self._bump(fid)

    def rename(self, fid: str, name: str):
        self.nodes[fid]["name"] = name
        self._bump(fid)

    def move(self, fid: str, parent: str):
        self.nodes[fid]["parent"] = parent
        self._bump(fid)

    def trash(self, fid: str):
        self.nodes[fid]["trashed"] = True
        self._bump(fid)

    def untrash(self, fid: str):
        self.nodes[fid]["trashed"] = False
        self._bump(fid)

    def delete(self, fid: str):
        self.nodes.pop(fid)
        self._bump(fid)

    def touch(self, fid: str, mtime: int):
        self.nodes[fid]["modifiedAt"] = mtime * 1000
        self._bump(fid)

    def invalidate_cursor(self):
        self.seq += 1                      # 幻影 seq：已發出的 token 全部落在 min_token 之前
        self.min_token = self.seq + 1

    def expire_token(self):
        self.token_valid = False

    def fail(self, kind: str, count: int, skip: int = 0):
        self.forced.extend([kind] * count)
        self.skip = skip

    # ---- HTTP
    def _file_json(self, fid: str, with_trashed: bool) -> dict:
        n = self.nodes[fid]
        out = {"id": fid, "name": n["name"], "mimeType": n["mimeType"],
               "parents": [n["parent"]], "modifiedTime": iso_ms(n["modifiedAt"])}
        if n["size"] is not None:
            out["size"] = str(n["size"])
        if n["md5"] is not None:
            out["md5Checksum"] = n["md5"]
        if with_trashed:
            out["trashed"] = n["trashed"]
        return out

    def handle(self, method: str, url: str, headers: dict) -> tuple[int, bytes]:
        self.requests += 1
        if self.forced:
            if self.skip > 0:
                self.skip -= 1
            else:
                kind = self.forced.pop(0)
                if kind == "transient":
                    return 503, b'{"error":{"code":503,"message":"Backend Error"}}'
                if kind == "ratelimit":
                    return 403, (b'{"error":{"code":403,"errors":[{"reason":"userRateLimitExceeded"}],'
                                 b'"message":"User Rate Limit Exceeded"}}')
                if kind == "notfound":
                    return 404, b'{"error":{"code":404,"message":"File not found"}}'
                if kind == "offline":
                    raise TransportError("offline")
                raise ValueError(kind)
        if headers.get("Authorization") != f"Bearer {self.current_token()}" or not self.token_valid:
            return 401, b'{"error":{"code":401,"message":"Invalid Credentials"}}'
        u = urlsplit(url)
        q = {k: v[0] for k, v in parse_qs(u.query).items()}
        path = u.path
        if path == "/drive/v3/changes/startPageToken":
            return 200, json.dumps({"startPageToken": str(self.seq + 1)}).encode()
        if path == "/drive/v3/changes":
            try:
                t = int(q["pageToken"])
            except (KeyError, ValueError):
                return 400, b'{"error":{"code":400,"message":"Invalid Value"}}'
            if t < self.min_token or t > self.seq + 1:
                return 400, b'{"error":{"code":400,"message":"Invalid Value"}}'
            cap = min(int(q.get("pageSize", PAGE_SIZE)), self.max_page)
            entries = [(s, f) for s, f in self.log if s >= t]
            page, rest = entries[:cap], entries[cap:]
            changes = []
            for _, fid in page:
                if fid in self.nodes:
                    changes.append({"fileId": fid, "removed": False,
                                    "file": self._file_json(fid, with_trashed=True)})
                else:
                    changes.append({"fileId": fid, "removed": True})
            out: dict = {"changes": changes}
            if rest:
                out["nextPageToken"] = str(rest[0][0])
            else:
                out["newStartPageToken"] = str(self.seq + 1)
            return 200, json.dumps(out).encode()
        if path == "/drive/v3/files":
            if q.get("q") != "trashed=false":
                return 400, b'{"error":{"code":400,"message":"Invalid Value"}}'
            cap = min(int(q.get("pageSize", PAGE_SIZE)), self.max_page)
            start = int(q.get("pageToken", "0"))
            ids = sorted(fid for fid, n in self.nodes.items() if not n["trashed"])
            page = ids[start:start + cap]
            out = {"files": [self._file_json(fid, with_trashed=False) for fid in page]}
            if start + cap < len(ids):
                out["nextPageToken"] = str(start + cap)
            return 200, json.dumps(out).encode()
        if path.startswith("/drive/v3/files/"):
            fid = path[len("/drive/v3/files/"):]
            n = self.nodes.get(fid)
            if n is None or n["trashed"] or q.get("alt") != "media":
                return 404, b'{"error":{"code":404,"message":"File not found"}}'
            data = n["data"]
            rng = headers.get("Range")
            if rng and rng.startswith("bytes="):
                a, b = rng[6:].split("-", 1)
                a = int(a)
                b = int(b) if b else len(data) - 1
                return 206, data[a:b + 1]
            return 200, data
        return 404, b'{"error":{"code":404,"message":"Not Found"}}'


# ---------------------------------------------------------------- GDriveProvider（參考實作）

class GDriveProvider:
    """provider.md §8。transport(method, url, headers) -> (status, body)；token_source 有 token()/refresh()。"""

    def __init__(self, root_id: str, transport, token_source, sleep):
        self.root_id = root_id
        self.transport = transport
        self.token_source = token_source
        self.sleep = sleep
        self.nodes: dict[str, dict] = {}
        self.cursor: str | None = None
        self.path_to_id: dict[str, str] = {}
        # 每輪統計（fixtures 觀測）
        self.reauths = 0
        self.sleeps: list[int] = []
        self.reset = False

    def begin_round(self):
        self.reauths, self.sleeps, self.reset = 0, [], False

    # ---- HTTP + §2.1 重試
    def _get(self, url: str, extra_headers: dict | None = None) -> bytes:
        return self._get_status(url, extra_headers)[1]

    def _get_status(self, url: str, extra_headers: dict | None = None) -> tuple[int, bytes]:
        transient = 0
        reauth_used = False
        token = self.token_source.token()
        while True:
            headers = {"Authorization": f"Bearer {token}"}
            if extra_headers:
                headers.update(extra_headers)
            try:
                status, body = self.transport("GET", url, headers)
            except TransportError:
                status, body = 0, b""
            if 200 <= status < 300:
                return status, body
            if status == 401:
                if reauth_used:
                    raise AuthError()
                reauth_used = True
                self.reauths += 1
                token = self.token_source.refresh()
                continue
            transient_kind = (status == 0 or status == 429 or status >= 500
                              or (status == 403 and b"ateLimitExceeded" in body))
            if transient_kind:
                if transient >= MAX_TRANSIENT_RETRIES:
                    raise TransientError()
                self.sleep(TRANSIENT_DELAYS[transient])
                self.sleeps.append(TRANSIENT_DELAYS[transient])
                transient += 1
                continue
            if status == 404:
                raise NotFoundError()
            raise HttpError(status)

    # ---- 節點表維護
    @staticmethod
    def _node(f: dict) -> dict:
        parents = f.get("parents") or []
        return dict(name=f["name"], mimeType=f["mimeType"],
                    parent=parents[0] if parents else None,
                    trashed=bool(f.get("trashed", False)),
                    size=int(f["size"]) if "size" in f else None,
                    md5=f.get("md5Checksum"),
                    modifiedAt=parse_iso_ms(f["modifiedTime"]))

    def _full(self):
        start = json.loads(self._get(f"{BASE}/changes/startPageToken"))["startPageToken"]
        self.nodes = {}
        page = None
        while True:
            url = f"{BASE}/files?q=trashed%3Dfalse&pageSize={PAGE_SIZE}&fields={LIST_FIELDS}"
            if page:
                url += f"&pageToken={page}"
            r = json.loads(self._get(url))
            for f in r.get("files", []):
                self.nodes[f["id"]] = self._node(f)
            page = r.get("nextPageToken")
            if not page:
                break
        self.cursor = start

    def _delta(self):
        page = self.cursor
        while True:
            url = (f"{BASE}/changes?pageToken={page}&pageSize={PAGE_SIZE}"
                   f"&includeRemoved=true&fields={CHANGE_FIELDS}")
            r = json.loads(self._get(url))
            for c in r.get("changes", []):
                if c.get("removed") or c.get("file", {}).get("trashed"):
                    self.nodes.pop(c["fileId"], None)
                else:
                    self.nodes[c["fileId"]] = self._node(c["file"])
            if r.get("nextPageToken"):
                page = r["nextPageToken"]
                continue
            self.cursor = r["newStartPageToken"]
            return

    def snapshot(self) -> dict[str, str]:
        if self.cursor is None:
            self._full()
        else:
            try:
                self._delta()
            except (NotFoundError, HttpError) as e:
                if isinstance(e, HttpError) and e.status != 400:
                    raise
                self.reset = True
                self.cursor = None
                self._full()
        return self._paths()

    def _paths(self) -> dict[str, str]:
        snap: dict[str, str] = {}
        self.path_to_id = {}
        for fid in sorted(self.nodes):
            n = self.nodes[fid]
            if n["mimeType"].startswith("application/vnd.google-apps."):
                continue
            names = []
            cur = n
            seen = {fid}
            ok = False
            while True:
                if cur["trashed"] or "/" in cur["name"]:
                    break
                names.append(cur["name"])
                pid = cur["parent"]
                if pid == self.root_id:
                    ok = True
                    break
                if pid is None or pid not in self.nodes or pid in seen:
                    break
                seen.add(pid)
                cur = self.nodes[pid]
            if not ok:
                continue
            path = "/".join(reversed(names))
            if path in snap:
                continue  # 同 path 碰撞：id 字典序最小者勝
            snap[path] = n["md5"] if n["md5"] else f"{n['size']}:{n['modifiedAt']}"
            self.path_to_id[path] = fid
        return snap

    def open(self, path: str) -> ByteSource | None:
        """ByteSource：size 取自節點 metadata；read = Range 請求（206；200 整檔則本地裁切）。"""
        fid = self.path_to_id.get(path)
        if fid is None:
            return None
        return _DriveSource(self, fid, self.nodes[fid]["size"] or 0)


class _DriveSource(ByteSource):
    def __init__(self, provider: "GDriveProvider", fid: str, size: int):
        self.provider, self.fid, self.size = provider, fid, size

    def read(self, offset: int, length: int) -> bytes:
        if length <= 0:
            return b""
        status, body = self.provider._get_status(
            f"{BASE}/files/{self.fid}?alt=media",
            {"Range": f"bytes={offset}-{offset + length - 1}"})
        return body if status == 206 else body[offset:offset + length]


def resolve_root(s: str) -> str | None:
    """資料夾 URL 或 id → id（純字串；各平台單元測試）。"""
    s = s.strip()
    if not s:
        return None
    if "://" not in s:
        return s
    u = urlsplit(s)
    q = parse_qs(u.query)
    if "id" in q:
        return q["id"][0]
    segs = [x for x in u.path.split("/") if x]
    for i, seg in enumerate(segs):
        if seg == "folders" and i + 1 < len(segs):
            return segs[i + 1]
    return None


# ---------------------------------------------------------------- driver

ROOT = "root0"


class TokenSource:
    def __init__(self, drive: FakeDrive):
        self.drive = drive

    def token(self) -> str:
        return self.drive.current_token()

    def refresh(self) -> str:
        return self.drive.issue_token()


def apply_op(drive: FakeDrive, op: dict, delete_after: list[str]):
    k = op["op"]
    if k == "mkdir":
        drive.mkdir(op["id"], op["name"], op["parent"], op.get("mtime", 1700000000))
    elif k == "put":
        data = ((ASSETS / op["asset"]).read_bytes() if "asset" in op
                else op["text"].encode("utf-8"))
        drive.put(op["id"], op["name"], op["parent"], data, op["mtime"],
                  mime=op.get("mime", "application/octet-stream"), md5=op.get("md5", True))
    elif k == "update":
        data = ((ASSETS / op["asset"]).read_bytes() if "asset" in op
                else op["text"].encode("utf-8"))
        drive.update(op["id"], data, op["mtime"])
    elif k == "rename":
        drive.rename(op["id"], op["name"])
    elif k == "move":
        drive.move(op["id"], op["parent"])
    elif k == "trash":
        drive.trash(op["id"])
    elif k == "untrash":
        drive.untrash(op["id"])
    elif k == "delete":
        drive.delete(op["id"])
    elif k == "touch":
        drive.touch(op["id"], op["mtime"])
    elif k == "invalidate_cursor":
        drive.invalidate_cursor()
    elif k == "expire_token":
        drive.expire_token()
    elif k == "fail":
        drive.fail(op["kind"], op["count"], op.get("skip", 0))
    elif k == "delete_after_delta":
        delete_after.append(op["id"])
    else:
        raise ValueError(k)


def run_case(case_dir: Path) -> list[dict]:
    script = json.loads((case_dir / "script.json").read_text(encoding="utf-8"))
    drive = FakeDrive(max_page=script.get("maxPage", PAGE_SIZE))
    provider = GDriveProvider(ROOT, drive.handle, TokenSource(drive), sleep=lambda ms: None)
    engine = SyncEngine(provider)
    out = []
    for step in script["steps"]:
        delete_after: list[str] = []
        for op in step["ops"]:
            apply_op(drive, op, delete_after)
        drive.requests = 0
        provider.begin_round()
        error = None
        try:
            report = engine.sync(after_delta=lambda ds=delete_after: [drive.delete(d) for d in ds])
        except AuthError:
            error, report = "auth", None
        except TransientError:
            error, report = "transient", None
        out.append({
            "provider": {
                "error": error,
                "reauths": provider.reauths,
                "requests": drive.requests,
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
        """共用前置：root/Aurora/Northern Lights/{01,02}.flac + Various/… + cover.jpg + Docs 檔。"""
        return [
            {"op": "mkdir", "id": "d-aurora", "name": "Aurora", "parent": ROOT},
            {"op": "mkdir", "id": "d-nl", "name": "Northern Lights", "parent": "d-aurora"},
            {"op": "put", "id": "f-rise", "name": "01 - Rise.flac", "parent": "d-nl",
             "asset": "flac_a", "mtime": 1700000100},
            {"op": "put", "id": "f-drift", "name": "02 - Drift.flac", "parent": "d-nl",
             "asset": "flac_b", "mtime": 1700000101},
            {"op": "put", "id": "f-cover", "name": "cover.jpg", "parent": "d-nl",
             "text": "not-a-real-jpg", "mtime": 1700000102},
            {"op": "mkdir", "id": "d-va", "name": "Various Artists", "parent": ROOT},
            {"op": "mkdir", "id": "d-mix", "name": "Dream Mixtape", "parent": "d-va"},
            {"op": "put", "id": "f-unknown", "name": "07 - Unknown.flac", "parent": "d-mix",
             "asset": "flac_notags", "mtime": 1700000103},
        ]

    return {
        "gdrive_initial_scan": {"steps": [
            {"ops": lib() + [
                # Google 文件（無 bytes）→ 排除
                {"op": "put", "id": "f-gdoc", "name": "notes.flac", "parent": "d-nl",
                 "text": "", "mtime": 1700000104, "mime": "application/vnd.google-apps.document",
                 "md5": False},
                # root 之外的檔案 → 不在庫內
                {"op": "mkdir", "id": "d-other", "name": "Other", "parent": "drive-root"},
                {"op": "put", "id": "f-other", "name": "03 - Elsewhere.flac", "parent": "d-other",
                 "asset": "flac_a", "mtime": 1700000105},
                # 已在垃圾桶
                {"op": "put", "id": "f-trashed", "name": "04 - Gone.flac", "parent": "d-nl",
                 "asset": "flac_b", "mtime": 1700000106},
                {"op": "trash", "id": "f-trashed"},
                # parent 鏈斷裂（parent 不存在）
                {"op": "put", "id": "f-orphan", "name": "05 - Orphan.flac", "parent": "d-missing",
                 "asset": "flac_b", "mtime": 1700000107},
            ]},
            {"ops": []},
        ]},
        "gdrive_paging": {"maxPage": 2, "steps": [
            {"ops": lib()},
            {"ops": [
                {"op": "put", "id": "f-ninjya", "name": "02 - Ninjya.mp3", "parent": "d-mix",
                 "asset": "mp3_tags", "mtime": 1700000200},
                {"op": "touch", "id": "f-rise", "mtime": 1700000201},
                {"op": "touch", "id": "f-drift", "mtime": 1700000202},
            ]},
            {"ops": []},
        ]},
        "gdrive_changes": {"steps": [
            {"ops": lib()},
            {"ops": [  # 改內容 → modified（md5 變）
                {"op": "update", "id": "f-rise", "asset": "flac_b", "mtime": 1700000300},
            ]},
            {"ops": [  # 改名 → removed + added，rev 不變
                {"op": "rename", "id": "f-drift", "name": "02 - Drifted.flac"},
            ]},
            {"ops": [  # modifiedTime 變、內容不變 → 無變更
                {"op": "touch", "id": "f-unknown", "mtime": 1700000400},
            ]},
            {"ops": [  # 資料夾從 root 外搬進來 → 整棵子樹進庫
                {"op": "mkdir", "id": "d-kyary", "name": "Kyary", "parent": "drive-root"},
                {"op": "mkdir", "id": "d-jelly", "name": "Jelly", "parent": "d-kyary"},
                {"op": "put", "id": "f-ninjya", "name": "02 - Ninjya.mp3", "parent": "d-jelly",
                 "asset": "mp3_tags", "mtime": 1700000500},
                {"op": "move", "id": "d-kyary", "parent": ROOT},
            ]},
            {"ops": [  # 資料夾進垃圾桶 → 子樹全部 removed
                {"op": "trash", "id": "d-kyary"},
            ]},
            {"ops": [  # 永久刪除 + 復原
                {"op": "delete", "id": "f-unknown"},
                {"op": "untrash", "id": "d-kyary"},
            ]},
            {"ops": [  # m3u8 生滅
                {"op": "put", "id": "f-pl", "name": "best.m3u8", "parent": ROOT, "mtime": 1700000600,
                 "text": "#EXTM3U\n#EXTINF:213.5,Rise\nAurora/Northern Lights/01 - Rise.flac\nKyary/Jelly/02 - Ninjya.mp3\n"},
            ]},
            {"ops": [
                {"op": "delete", "id": "f-pl"},
            ]},
        ]},
        "gdrive_cursor_reset": {"steps": [
            {"ops": lib()},
            {"ops": [
                {"op": "put", "id": "f-ninjya", "name": "02 - Ninjya.mp3", "parent": "d-mix",
                 "asset": "mp3_tags", "mtime": 1700000700},
                {"op": "invalidate_cursor"},
            ]},
            {"ops": []},
        ]},
        "gdrive_retry": {"steps": [
            {"ops": lib()},
            {"ops": [  # token 過期 → 401 → refresh 一次 → 繼續
                {"op": "expire_token"},
            ]},
            {"ops": [  # 503×2 → 1s/2s 退避後成功；403 rateLimit 也是 transient
                {"op": "fail", "kind": "transient", "count": 2},
                {"op": "fail", "kind": "ratelimit", "count": 1},
                {"op": "put", "id": "f-ninjya", "name": "02 - Ninjya.mp3", "parent": "d-mix",
                 "asset": "mp3_tags", "mtime": 1700000800},
            ]},
            {"ops": [  # delta 階段連線失敗耗盡 → 整輪拋錯，索引與 cursor 不動
                {"op": "fail", "kind": "offline", "count": 6},
                {"op": "put", "id": "f-north", "name": "03 - North.m4a", "parent": "d-mix",
                 "asset": "m4a_tags", "mtime": 1700000801},
            ]},
            {"ops": []},  # 上輪的變更這輪補上
        ]},
        "gdrive_scan_resume": {"steps": [
            {"ops": [
                {"op": "mkdir", "id": "d-aurora", "name": "Aurora", "parent": ROOT},
                {"op": "mkdir", "id": "d-nl", "name": "Northern Lights", "parent": "d-aurora"},
            ]},
            {"ops": [  # 3 檔 pending；第 2 個下載耗盡 → 第 2、3 檔 unscanned
                {"op": "put", "id": "f-a", "name": "01 - Rise.flac", "parent": "d-nl",
                 "asset": "flac_a", "mtime": 1700000900},
                {"op": "put", "id": "f-b", "name": "02 - Drift.flac", "parent": "d-nl",
                 "asset": "flac_b", "mtime": 1700000901},
                {"op": "put", "id": "f-c", "name": "03 - Unknown.flac", "parent": "d-nl",
                 "asset": "flac_notags", "mtime": 1700000902},
                {"op": "fail", "kind": "transient", "count": 6, "skip": 2},  # changes.list + 第 1 個下載放行
            ]},
            {"ops": []},  # 續掃：第 2、3 檔再次 added
            {"ops": [  # delta 後檔案被拔 → 404 → 靜默丟棄；下輪補 removed
                {"op": "put", "id": "f-d", "name": "04 - Ghost.flac", "parent": "d-nl",
                 "asset": "flac_b", "mtime": 1700000903},
                {"op": "delete_after_delta", "id": "f-d"},
            ]},
            {"ops": []},
        ]},
        "gdrive_windowed_scan": {"steps": [
            {"ops": [  # 三個 >64KB 的檔：只抓結構需要的 chunk（model.md §1.8）
                {"op": "mkdir", "id": "d-big", "name": "Big", "parent": ROOT},
                {"op": "put", "id": "f-m4a", "name": "01 - Tail Moov.m4a", "parent": "d-big",
                 "asset": "m4a_tail_big", "mtime": 1700001100},
                {"op": "put", "id": "f-flac", "name": "02 - Big Pic.flac", "parent": "d-big",
                 "asset": "flac_bigpic", "mtime": 1700001101},
                {"op": "put", "id": "f-mp3", "name": "03 - Big Apic.mp3", "parent": "d-big",
                 "asset": "mp3_bigapic", "mtime": 1700001102},
            ]},
            {"ops": []},
        ]},
        "gdrive_collision": {"steps": [
            {"ops": [
                {"op": "mkdir", "id": "d-a", "name": "Aurora", "parent": ROOT},
                {"op": "mkdir", "id": "d-b", "name": "Northern Lights", "parent": "d-a"},
                # 同資料夾同名：id 字典序最小者勝
                {"op": "put", "id": "f-2", "name": "01 - Rise.flac", "parent": "d-b",
                 "asset": "flac_b", "mtime": 1700001000},
                {"op": "put", "id": "f-1", "name": "01 - Rise.flac", "parent": "d-b",
                 "asset": "flac_a", "mtime": 1700001001},
                # 名稱含 '/' → 排除
                {"op": "put", "id": "f-slash", "name": "02 - A/B.flac", "parent": "d-b",
                 "asset": "flac_b", "mtime": 1700001002},
                # 無 parents（共享檔）→ 排除
                {"op": "put", "id": "f-noparent", "name": "03 - Shared.flac", "parent": None,
                 "asset": "flac_b", "mtime": 1700001003},
            ]},
            {"ops": [  # 勝者刪除 → 敗者浮現（同 path 變 modified：rev 換成敗者的 md5）
                {"op": "delete", "id": "f-1"},
            ]},
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

    s = step("gdrive_initial_scan", 0)
    paths = sorted(t["path"] for t in s["report"]["index"]["tracks"])
    assert paths == ["Aurora/Northern Lights/01 - Rise.flac",
                     "Aurora/Northern Lights/02 - Drift.flac",
                     "Various Artists/Dream Mixtape/07 - Unknown.flac"], paths
    assert s["provider"]["requests"] == 1 + 1 + 3, s["provider"]  # startPageToken + files.list + 3 下載
    assert s["provider"]["reset"] is False
    s = step("gdrive_initial_scan", 1)
    assert s["report"]["changes"] == [] and s["provider"]["requests"] == 1, s["provider"]

    s = step("gdrive_paging", 0)
    assert s["provider"]["requests"] == 1 + 4 + 3, s["provider"]  # 8 nodes / 2 per page
    s = step("gdrive_paging", 1)
    assert s["provider"]["requests"] == 2 + 1, s["provider"]  # 3 changes / 2 per page + 1 下載
    assert [c["kind"] for c in s["report"]["changes"]] == ["added"]

    s = step("gdrive_changes", 1)
    assert [c["kind"] for c in s["report"]["changes"]] == ["modified"]
    assert {t["path"]: t for t in s["report"]["index"]["tracks"]}[
        "Aurora/Northern Lights/01 - Rise.flac"]["title"] == "Drift"
    s = step("gdrive_changes", 2)
    kinds = sorted((c["path"], c["kind"]) for c in s["report"]["changes"])
    assert kinds == [("Aurora/Northern Lights/02 - Drift.flac", "removed"),
                     ("Aurora/Northern Lights/02 - Drifted.flac", "added")], kinds
    assert len({c["rev"] for c in s["report"]["changes"]}) == 1, "改名 rev 不變"
    s = step("gdrive_changes", 3)
    assert s["report"]["changes"] == [] and s["report"]["scanned"] == [], "touch → 無變更"
    s = step("gdrive_changes", 4)
    assert [c["path"] for c in s["report"]["changes"]] == ["Kyary/Jelly/02 - Ninjya.mp3"]
    s = step("gdrive_changes", 5)
    assert [(c["path"], c["kind"]) for c in s["report"]["changes"]] == \
        [("Kyary/Jelly/02 - Ninjya.mp3", "removed")]
    s = step("gdrive_changes", 6)
    kinds = sorted((c["path"], c["kind"]) for c in s["report"]["changes"])
    assert kinds == [("Kyary/Jelly/02 - Ninjya.mp3", "added"),
                     ("Various Artists/Dream Mixtape/07 - Unknown.flac", "removed")], kinds
    assert s["report"]["scanned"] == ["Kyary/Jelly/02 - Ninjya.mp3"], "untrash = 重新 added（cursor 已無該 path）→ 重掃"
    s = step("gdrive_changes", 7)
    items = s["report"]["index"]["playlists"][0]["items"]
    assert [it["missing"] for it in items] == [False, False], items

    s = step("gdrive_cursor_reset", 1)
    assert s["provider"]["reset"] is True
    assert s["provider"]["requests"] == 1 + 1 + 1 + 1, s["provider"]  # changes(400) + start + list + 1 下載
    assert [c["kind"] for c in s["report"]["changes"]] == ["added"], "reset 後 rev 未變者不重掃"
    s = step("gdrive_cursor_reset", 2)
    assert s["provider"]["reset"] is False and s["report"]["changes"] == []

    s = step("gdrive_retry", 1)
    assert s["provider"]["reauths"] == 1 and s["provider"]["error"] is None, s["provider"]
    s = step("gdrive_retry", 2)
    assert s["provider"]["sleeps"] == [1000, 2000, 4000], s["provider"]
    assert s["provider"]["requests"] == 3 + 1 + 1, s["provider"]
    s = step("gdrive_retry", 3)
    assert s["provider"]["error"] == "transient" and s["report"] is None
    assert s["provider"]["sleeps"] == [1000, 2000, 4000, 8000, 16000]
    s = step("gdrive_retry", 4)
    assert [c["path"] for c in s["report"]["changes"]] == \
        ["Various Artists/Dream Mixtape/03 - North.m4a"], "拋錯那輪的變更下輪補上"

    s = step("gdrive_scan_resume", 1)
    assert s["provider"]["unscanned"] == ["Aurora/Northern Lights/02 - Drift.flac",
                                          "Aurora/Northern Lights/03 - Unknown.flac"]
    assert s["report"]["scanned"] == ["Aurora/Northern Lights/01 - Rise.flac"]
    assert len(s["report"]["changes"]) == 3
    s = step("gdrive_scan_resume", 2)
    assert sorted(c["path"] for c in s["report"]["changes"]) == \
        ["Aurora/Northern Lights/02 - Drift.flac", "Aurora/Northern Lights/03 - Unknown.flac"]
    assert len(s["report"]["scanned"]) == 2 and s["provider"]["unscanned"] == []
    s = step("gdrive_scan_resume", 3)
    assert s["report"]["scanned"] == [] and \
        [c["kind"] for c in s["report"]["changes"]] == ["added"]
    s = step("gdrive_scan_resume", 4)
    assert [c["kind"] for c in s["report"]["changes"]] == ["removed"]
    assert all(t["path"] != "Aurora/Northern Lights/04 - Ghost.flac"
               for t in s["report"]["index"]["tracks"])

    s = step("gdrive_collision", 0)
    tr = s["report"]["index"]["tracks"]
    assert [t["path"] for t in tr] == ["Aurora/Northern Lights/01 - Rise.flac"], tr
    assert tr[0]["title"] == "Rise", "id 字典序最小者（f-1）勝"
    s = step("gdrive_collision", 1)
    assert [c["kind"] for c in s["report"]["changes"]] == ["modified"]
    assert s["report"]["index"]["tracks"][0]["title"] == "Drift"

    s = step("gdrive_windowed_scan", 0)
    assert s["provider"]["requests"] == 1 + 1 + 2 + 2 + 2, s["provider"]  # 每檔 2 chunk（頭 + tag 所在）
    tr = {t["path"]: t for t in s["report"]["index"]["tracks"]}
    m4a = tr["Big/01 - Tail Moov.m4a"]
    assert (m4a["title"], m4a["artist"], m4a["trackNo"], m4a["durationMs"]) == ("Tail Moov", "Becko", 2, 10000), m4a
    fl = tr["Big/02 - Big Pic.flac"]
    assert fl["title"] == "Rise" and fl["tagOk"] is True and fl["sizeBytes"] > 150000, fl
    mp = tr["Big/03 - Big Apic.mp3"]
    assert (mp["title"], mp["trackNo"], mp["durationMs"]) == ("Big Cover", 3, 250), mp

    assert resolve_root("https://drive.google.com/drive/u/0/folders/abc123?usp=sharing") == "abc123"
    assert resolve_root("https://drive.google.com/open?id=xyz") == "xyz"
    assert resolve_root(" abc ") == "abc" and resolve_root("") is None
    print(f"OK: {len(scripts)} gdrive cases generated, all sanity asserts passed")


def check() -> int:
    bad = []
    for case in sorted(CASES.iterdir()):
        if not case.is_dir():
            continue
        actual = canonical(run_case(case))
        expected_path = case / "expected.json"
        if not expected_path.exists() or \
                expected_path.read_text(encoding="utf-8") != actual:
            bad.append(case.name)
    if bad:
        print(f"DRIFT: {len(bad)} gdrive case(s) differ: {', '.join(bad)}")
        return 1
    print("OK: all gdrive cases byte-identical to expected.json")
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
