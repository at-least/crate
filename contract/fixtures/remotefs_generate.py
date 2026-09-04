#!/usr/bin/env python3
"""
Crate 遠端檔案系統 provider（SFTP / SMB）契約 fixtures 產生器（兼 Python 參考實作）

- provider.md §11：RemoteFsProvider（全量 walk、rev=size:mtime、symlink 忽略、深度上限、
  SMB 大小寫不敏感與碰撞規則；§11.4 錯誤對應套 §2.1）
- FakeRemoteFs：協定語意層的 in-memory 遠端檔案系統（三實作各自複製同一份語意；本檔為參考）
- 產出 remotefs_cases/<name>/script.json + expected.json（每步 = {provider 統計, SyncReport}）

重跑：python3 remotefs_generate.py          （重寫 script + expected）
驗證：python3 remotefs_generate.py --check  （重放比對 expected；無 ffmpeg，可進 CI）
"""
import json, sys
from pathlib import Path

from generate import canonical, ByteSource
from sync_generate import ASSETS, SyncEngine, ProviderError, NotFoundError
from gdrive_generate import (AuthError, TransientError,
                             TRANSIENT_DELAYS, MAX_TRANSIENT_RETRIES)

HERE = Path(__file__).parent
CASES = HERE / "remotefs_cases"

MAX_DEPTH = 64          # provider.md §11.2（root 為 0）
READ_CHUNK = 64 * 1024  # 觀測用；實際切塊由 ChunkedReader 決定


def ub(s: str) -> bytes:
    """UTF-8 位元組序排序鍵（§11.2；刻意不用各語言預設字串比較）。"""
    return s.encode("utf-8")


# ---------------------------------------------------------------- FakeRemoteFs（協定語意層）

class FakeRemoteFs:
    """
    in-memory 遠端檔案系統。SFTP = case_insensitive False；SMB = True。

    故障腳本 faults：每次 transport 操作（connect / list_dir / read）從佇列取一個標記，
    "auth" / "disconnect" / "notfound" / "ok"（或佇列空）= 正常。
    """

    def __init__(self, case_insensitive: bool = False):
        self.case_insensitive = case_insensitive
        self.files: dict[str, dict] = {}   # path -> {data, mtime, symlink}
        self.dirs: set[str] = set()
        self.faults: list[str] = []
        self.connected = False
        # 每輪統計（fixtures 觀測）
        self.connects = 0
        self.listdirs = 0
        self.reads = 0

    # ---- 測試腳本用（不是協定的一部分）
    def put(self, path: str, data: bytes, mtime_ms: int, symlink: bool = False):
        self.files[path] = {"data": data, "mtime": mtime_ms, "symlink": symlink}
        parts = path.split("/")[:-1]
        for i in range(len(parts)):
            self.dirs.add("/".join(parts[:i + 1]))

    def mkdir(self, path: str):
        parts = path.split("/")
        for i in range(len(parts)):
            self.dirs.add("/".join(parts[:i + 1]))

    def delete(self, path: str):
        self.files.pop(path, None)

    def rename(self, src: str, dst: str):
        f = self.files.pop(src)
        self.put(dst, f["data"], f["mtime"], f["symlink"])

    def touch(self, path: str, mtime_ms: int):
        self.files[path]["mtime"] = mtime_ms

    # ---- 協定面
    def _fault(self):
        kind = self.faults.pop(0) if self.faults else "ok"
        if kind == "auth":
            raise AuthError()
        if kind == "disconnect":
            self.connected = False
            raise TransientError()
        if kind == "notfound":
            raise NotFoundError()
        if kind != "ok":
            raise ValueError(kind)

    def connect(self):
        self.connects += 1
        self._fault()
        self.connected = True

    def disconnect(self):
        self.connected = False

    def _require_session(self):
        if not self.connected:
            raise TransientError()

    def list_dir(self, path: str) -> list[dict]:
        self.listdirs += 1
        self._require_session()
        self._fault()
        if path and path not in self.dirs:
            raise NotFoundError()
        prefix = f"{path}/" if path else ""
        out: dict[str, dict] = {}
        for p, f in self.files.items():
            if not p.startswith(prefix):
                continue
            rest = p[len(prefix):]
            if "/" in rest:
                continue
            out[rest] = {"name": rest, "isDir": False, "isSymlink": f["symlink"],
                         "sizeBytes": len(f["data"]), "mtimeMs": f["mtime"]}
        for d in self.dirs:
            if not d.startswith(prefix):
                continue
            rest = d[len(prefix):]
            if not rest or "/" in rest:
                continue
            out.setdefault(rest, {"name": rest, "isDir": True, "isSymlink": False,
                                  "sizeBytes": 0, "mtimeMs": 0})
        return list(out.values())

    def read(self, path: str, offset: int, length: int) -> bytes:
        self.reads += 1
        self._require_session()
        self._fault()
        f = self.files.get(path)
        if f is None:
            raise NotFoundError()
        return f["data"][offset:offset + length]


# ---------------------------------------------------------------- 憑證

class CredentialSource:
    def __init__(self):
        self.invalidations = 0

    def credential(self) -> str:
        return "cred"

    def invalidate(self):
        self.invalidations += 1


# ---------------------------------------------------------------- RemoteFsProvider

class RemoteFsProvider:
    """provider.md §11。fs = FsTransport；cred = CredentialSource。"""

    def __init__(self, fs: FakeRemoteFs, root: str, cred: CredentialSource, sleep,
                 case_insensitive: bool = False):
        self.fs = fs
        self.root = root
        self.cred = cred
        self.sleep = sleep
        self.case_insensitive = case_insensitive
        self.sizes: dict[str, int] = {}
        # 每輪統計
        self.reauths = 0
        self.sleeps: list[int] = []

    def begin_round(self):
        self.reauths, self.sleeps = 0, []

    def _abs(self, rel: str) -> str:
        if not self.root:
            return rel
        return f"{self.root}/{rel}" if rel else self.root

    # ---- §11.4：每個 transport 操作各自套 §2.1
    def _op(self, fn):
        transient = 0
        reauth_used = False
        while True:
            try:
                if not self.fs.connected:
                    self.fs.connect()
                return fn()
            except AuthError:
                if reauth_used:
                    raise
                reauth_used = True
                self.reauths += 1
                self.cred.invalidate()
                self.fs.disconnect()
                continue  # 立即重試（不退避；§2.1 重授權與退避分開計數）
            except TransientError:
                if transient >= MAX_TRANSIENT_RETRIES:
                    raise
                self.sleep(TRANSIENT_DELAYS[transient])
                self.sleeps.append(TRANSIENT_DELAYS[transient])
                transient += 1
                self.fs.disconnect()  # 每次重試前重連
                continue

    # ---- §11.2 walk
    def snapshot(self) -> dict[str, str]:
        snap: dict[str, str] = {}
        keys: dict[str, str] = {}
        self.sizes = {}
        self._walk("", 0, snap, keys)
        return snap

    def _walk(self, rel: str, depth: int, snap: dict, keys: dict):
        if depth > MAX_DEPTH:
            return
        try:
            entries = self._op(lambda: self.fs.list_dir(self._abs(rel)))
        except NotFoundError:
            return  # 掃描期間目錄被刪 → 該子樹視為空，不中斷整輪
        for e in sorted(entries, key=lambda x: ub(x["name"])):
            name = e["name"]
            if e["isSymlink"]:
                continue
            if not name or name in (".", "..") or "/" in name:
                continue
            child = f"{rel}/{name}" if rel else name
            if e["isDir"]:
                self._walk(child, depth + 1, snap, keys)
                continue
            key = child.lower() if self.case_insensitive else child
            prev = keys.get(key)
            if prev is not None:
                if ub(child) >= ub(prev):
                    continue  # 碰撞：UTF-8 位元組序最小者勝
                snap.pop(prev, None)
                self.sizes.pop(prev, None)
            keys[key] = child
            snap[child] = f'{e["sizeBytes"]}:{e["mtimeMs"]}'
            self.sizes[child] = e["sizeBytes"]

    def open(self, path: str) -> ByteSource | None:
        size = self.sizes.get(path)
        if size is None:
            return None
        return _FsSource(self, path, size)


class _FsSource(ByteSource):
    def __init__(self, provider: RemoteFsProvider, path: str, size: int):
        self.provider, self.path, self.size = provider, path, size

    def read(self, offset: int, length: int) -> bytes:
        if length <= 0:
            return b""
        p = self.provider
        return p._op(lambda: p.fs.read(p._abs(self.path), offset, length))


# ---------------------------------------------------------------- driver

ROOT = "lib"


def apply_op(fs: FakeRemoteFs, op: dict, delete_after: list[str]):
    k = op["op"]
    if k == "write":
        data = ((ASSETS / op["asset"]).read_bytes() if "asset" in op
                else op["text"].encode("utf-8"))
        fs.put(f"{ROOT}/{op['path']}", data, op["mtime"] * 1000,
               symlink=op.get("symlink", False))
    elif k == "mkdir":
        fs.mkdir(f"{ROOT}/{op['path']}")
    elif k == "delete":
        fs.delete(f"{ROOT}/{op['path']}")
    elif k == "rename":
        fs.rename(f"{ROOT}/{op['from']}", f"{ROOT}/{op['to']}")
    elif k == "touch":
        fs.touch(f"{ROOT}/{op['path']}", op["mtime"] * 1000)
    elif k == "faults":
        fs.faults = list(op["queue"])
    elif k == "delete_after_delta":
        delete_after.append(op["path"])
    else:
        raise ValueError(k)


def run_case(case_dir: Path) -> list[dict]:
    script = json.loads((case_dir / "script.json").read_text(encoding="utf-8"))
    ci = script.get("caseInsensitive", False)
    fs = FakeRemoteFs(case_insensitive=ci)
    cred = CredentialSource()
    provider = RemoteFsProvider(fs, ROOT, cred, sleep=lambda ms: None,
                                case_insensitive=ci)
    engine = SyncEngine(provider)
    out = []
    for step in script["steps"]:
        delete_after: list[str] = []
        for op in step["ops"]:
            apply_op(fs, op, delete_after)
        fs.connects = fs.listdirs = fs.reads = 0
        provider.begin_round()
        error = None
        try:
            report = engine.sync(
                after_delta=lambda ds=delete_after: [fs.delete(f"{ROOT}/{d}") for d in ds])
        except AuthError:
            error, report = "auth", None
        except TransientError:
            error, report = "transient", None
        out.append({
            "provider": {
                "connects": fs.connects,
                "error": error,
                "listDirs": fs.listdirs,
                "reads": fs.reads,
                "reauths": provider.reauths,
                "sleeps": list(provider.sleeps),
                "unscanned": list(engine.unscanned) if error is None else [],
            },
            "report": report,
        })
    return out


# ---------------------------------------------------------------- cases

A = "Aurora/Northern Lights/01 - Rise.flac"
B = "Aurora/Northern Lights/02 - Drift.flac"
C = "Kyary/Jelly/01 - Ninjya.mp3"


def build_scripts() -> dict[str, dict]:
    return {
        # 首掃：巢狀樹全量 walk。listDirs = root + Aurora + Northern Lights + Kyary + Jelly。
        "remotefs_initial_scan": {"steps": [
            {"ops": [
                {"op": "write", "path": A, "asset": "flac_a", "mtime": 1700000100},
                {"op": "write", "path": B, "asset": "flac_b", "mtime": 1700000200},
                {"op": "write", "path": C, "asset": "mp3_tags", "mtime": 1700000300},
            ]},
        ]},

        # 增量：新增 / 內容改 / 刪除，各自對應 added / modified / removed。
        "remotefs_changes": {"steps": [
            {"ops": [
                {"op": "write", "path": A, "asset": "flac_a", "mtime": 1700000100},
                {"op": "write", "path": B, "asset": "flac_b", "mtime": 1700000200},
            ]},
            {"ops": [
                {"op": "write", "path": C, "asset": "mp3_tags", "mtime": 1700000300},
                {"op": "write", "path": B, "asset": "m4a_tags", "mtime": 1700000400},
                {"op": "delete", "path": A},
            ]},
        ]},

        # §11.3：改名 = removed(舊) + added(新)，rev 不變（遠端 fs 無穩定 file id）。
        "remotefs_rename": {"steps": [
            {"ops": [
                {"op": "write", "path": A, "asset": "flac_a", "mtime": 1700000100},
            ]},
            {"ops": [
                {"op": "rename", "from": A, "to": "Aurora/Northern Lights/01 - Sunrise.flac"},
            ]},
        ]},

        # §11.3：mtime 動、內容沒動 → 仍算 modified（rev 含 mtime 的直接後果）。
        "remotefs_touch_only": {"steps": [
            {"ops": [
                {"op": "write", "path": A, "asset": "flac_a", "mtime": 1700000100},
            ]},
            {"ops": [
                {"op": "touch", "path": A, "mtime": 1700000999},
            ]},
        ]},

        # §11.2：symlink 不跟隨不入庫；深度上限之內的深層樹照掃。
        "remotefs_symlink_skipped": {"steps": [
            {"ops": [
                {"op": "write", "path": A, "asset": "flac_a", "mtime": 1700000100},
                {"op": "write", "path": "Aurora/Northern Lights/link.flac",
                 "asset": "flac_b", "mtime": 1700000200, "symlink": True},
                {"op": "mkdir", "path": "Empty"},
            ]},
        ]},

        # §11.4：walk 途中斷線 → 退避 1/2/4s 後重連續走；每次重試前重連（connects 隨之增加）。
        "remotefs_retry": {"steps": [
            {"ops": [
                {"op": "write", "path": A, "asset": "flac_a", "mtime": 1700000100},
                {"op": "faults", "queue": ["ok", "disconnect", "ok",
                                           "disconnect", "ok", "disconnect", "ok"]},
            ]},
        ]},

        # §11.4：憑證被拒 → invalidate + 重連一次即成功（不退避，sleeps 為空）。
        "remotefs_reauth": {"steps": [
            {"ops": [
                {"op": "write", "path": A, "asset": "flac_a", "mtime": 1700000100},
                {"op": "faults", "queue": ["auth"]},
            ]},
        ]},

        # §11.4：連兩次認證失敗 → 傳播（整輪 sync 拋錯，索引與 cursor 不動）。
        "remotefs_auth_fatal": {"steps": [
            {"ops": [
                {"op": "write", "path": A, "asset": "flac_a", "mtime": 1700000100},
                {"op": "faults", "queue": ["auth", "auth"]},
            ]},
            {"ops": [{"op": "faults", "queue": []}]},
        ]},

        # §3.2-8：單檔重試耗盡 → 該檔與本輪剩餘 pending 全部 unscanned，下輪接續。
        "remotefs_scan_resume": {"steps": [
            {"ops": [
                {"op": "write", "path": A, "asset": "flac_a", "mtime": 1700000100},
                {"op": "write", "path": B, "asset": "flac_b", "mtime": 1700000200},
                {"op": "faults", "queue": ["ok", "ok", "ok", "ok",
                                           "disconnect",
                                           "ok", "disconnect", "ok", "disconnect",
                                           "ok", "disconnect", "ok", "disconnect",
                                           "ok", "disconnect"]},
            ]},
            {"ops": [{"op": "faults", "queue": []}]},
        ]},

        # §3.2-4：delta 之後、掃描之前檔案消失 → 靜默丟棄（不進 errors）。
        "remotefs_vanished": {"steps": [
            {"ops": [
                {"op": "write", "path": A, "asset": "flac_a", "mtime": 1700000100},
                {"op": "write", "path": B, "asset": "flac_b", "mtime": 1700000200},
                {"op": "delete_after_delta", "path": A},
            ]},
        ]},

        # §11.2 / §5：視窗化讀取——moov 在檔尾的 m4a 與大封面 FLAC 只抓需要的 chunk。
        "remotefs_windowed_scan": {"steps": [
            {"ops": [
                {"op": "write", "path": "Big/Cover/01 - Big.flac",
                 "asset": "flac_bigpic", "mtime": 1700000100},
                {"op": "write", "path": "Big/Tail/02 - Tail.m4a",
                 "asset": "m4a_tail_big", "mtime": 1700000200},
            ]},
        ]},

        # §11.7：SMB 不分大小寫——同一目錄下僅大小寫不同 → UTF-8 位元組序最小者勝。
        "remotefs_smb_case": {"caseInsensitive": True, "steps": [
            {"ops": [
                {"op": "write", "path": "Aurora/Northern Lights/01 - Rise.flac",
                 "asset": "flac_a", "mtime": 1700000100},
                {"op": "write", "path": "Aurora/Northern Lights/01 - RISE.flac",
                 "asset": "flac_b", "mtime": 1700000200},
            ]},
        ]},

        # §11.7：SMB 下純改大小寫的更名——key 不變，引擎 path 換成新的原始大小寫。
        "remotefs_smb_case_rename": {"caseInsensitive": True, "steps": [
            {"ops": [
                {"op": "write", "path": "Aurora/Northern Lights/01 - Rise.flac",
                 "asset": "flac_a", "mtime": 1700000100},
            ]},
            {"ops": [
                {"op": "rename", "from": "Aurora/Northern Lights/01 - Rise.flac",
                 "to": "Aurora/Northern Lights/01 - RISE.flac"},
            ]},
        ]},

        # m3u8 在遠端 fs 上與本地同語意（整檔 readText → raw 解析）。
        "remotefs_playlist": {"steps": [
            {"ops": [
                {"op": "write", "path": A, "asset": "flac_a", "mtime": 1700000100},
                {"op": "write", "path": B, "asset": "flac_b", "mtime": 1700000200},
                {"op": "write", "path": "清單/我的最愛.m3u8", "mtime": 1700000300,
                 "text": "#EXTM3U\n#EXTINF:180,Rise\n../Aurora/Northern Lights/01 - Rise.flac\n"
                         "#EXTINF:200,Gone\n../Aurora/Northern Lights/99 - Gone.flac\n"},
            ]},
        ]},
    }


# ---------------------------------------------------------------- main

def main():
    CASES.mkdir(exist_ok=True)
    scripts = build_scripts()
    for name, script in scripts.items():
        d = CASES / name
        d.mkdir(exist_ok=True)
        (d / "script.json").write_text(canonical(script), encoding="utf-8")
        (d / "expected.json").write_text(canonical(run_case(d)), encoding="utf-8")
    print(f"OK: {len(scripts)} remotefs cases -> {CASES}")


def check() -> int:
    bad = []
    names = sorted(p.name for p in CASES.iterdir() if p.is_dir())
    for name in names:
        d = CASES / name
        got = canonical(run_case(d))
        want = (d / "expected.json").read_text(encoding="utf-8")
        if got != want:
            bad.append(name)
    if bad:
        print(f"MISMATCH: {', '.join(bad)}")
        return 1
    print(f"OK: all {len(names)} remotefs cases byte-identical to expected.json")
    return 0


if __name__ == "__main__":
    sys.exit(check() if "--check" in sys.argv else (main() or 0))
