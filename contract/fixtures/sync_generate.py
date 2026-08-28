#!/usr/bin/env python3
"""
Mu 同步引擎契約 fixtures 產生器（兼 Python 參考實作）

- sync_assets/：共享音訊資產（ffmpeg 生成後 commit；平台測試直接取用位元組）
- sync_cases/<name>/script.json + expected.json（每步一輪 sync() 的 SyncReport）
- 引擎規格：contract/sync-rules.md §3；本地 provider 語意：contract/provider.md §6

重跑：python3 sync_generate.py          （需 ffmpeg；產物已 commit，平時不需要重跑）
驗證：python3 sync_generate.py --check  （重放 script 比對 expected.json；無 ffmpeg，可進 CI）
"""
import json, os, sys, tempfile
from pathlib import Path

from generate import (audio_bytes, parse_tags, parse_duration, fmt_for, make_track,
                      group_albums, canonical, _norm_path, _extinf_to_ms)

HERE = Path(__file__).parent
ASSETS = HERE / "sync_assets"
CASES = HERE / "sync_cases"

# ---------------------------------------------------------------- assets

ASSET_SPECS = {
    "flac_a": dict(fmt="flac", meta={
        "title": "Rise", "artist": "Aurora", "album": "Northern Lights",
        "album_artist": "Aurora", "track_number": "1", "date": "2021"}),
    "flac_b": dict(fmt="flac", meta={
        "title": "Drift", "artist": "Aurora", "album": "Northern Lights",
        "album_artist": "Aurora", "track_number": "2", "date": "2021"}),
    "flac_notags": dict(fmt="flac", meta=None),
    "mp3_tags": dict(fmt="mp3", meta={
        "title": "Ninjya", "artist": "Kyary", "album": "Jelly"}),
    "m4a_tags": dict(fmt="m4a", meta={
        "title": "North", "artist": "Becko", "album": "Vector"}),
}

def build_assets():
    ASSETS.mkdir(exist_ok=True)
    for name, spec in ASSET_SPECS.items():
        (ASSETS / name).write_bytes(audio_bytes(spec["fmt"], spec["meta"]))
    print(f"OK: {len(ASSET_SPECS)} assets -> {ASSETS}")

# ---------------------------------------------------------------- m3u8 raw parse

def parse_m3u8_raw(text: str, rel: str) -> dict:
    """model.md §2.3 的 raw 部分（不解析 trackId；輸出時才對 available 集合解析）。"""
    text = text.lstrip("\ufeff")
    items, pending_dur = [], None
    for line in text.replace("\r\n", "\n").split("\n"):
        line = line.strip()
        if not line:
            continue
        if line.startswith("#"):
            if line.startswith("#EXTINF:"):
                pending_dur = _extinf_to_ms(line[len("#EXTINF:"):].split(",", 1)[0])
            continue
        ref = line.replace("\\", "/")
        while ref.startswith("./"):
            ref = ref[2:]
        items.append({"durationMs": pending_dur, "position": len(items), "ref": ref})
        pending_dur = None
    name = rel.split("/")[-1][:-5]
    return {"items": items, "name": name}

# ---------------------------------------------------------------- engine

class ProviderError(Exception):
    """provider 層非 NotFound 的失敗（重試耗盡等）；引擎據此走 §3.2-8 續掃。"""


class LocalProvider:
    """provider.md §6：snapshot = 全量 walk（path -> "{size}:{mtimeMs}"）；read_bytes None = NotFound。"""

    def __init__(self, root: Path):
        self.root = root

    def snapshot(self) -> dict[str, str]:
        snap: dict[str, str] = {}
        for dirpath, _, fns in os.walk(self.root):
            for fn in fns:
                p = Path(dirpath) / fn
                rel = p.relative_to(self.root).as_posix()
                st = p.stat()
                snap[rel] = f"{st.st_size}:{int(round(st.st_mtime * 1000))}"
        return snap

    def read_bytes(self, path: str) -> bytes | None:
        try:
            return (self.root / path).read_bytes()
        except FileNotFoundError:
            return None


class SyncEngine:
    """sync-rules.md §3 的參考實作。provider = snapshot()/read_bytes() 兩面（§6 本地、§8 GDrive）。"""

    def __init__(self, provider):
        self.provider = provider
        self.cursor: dict[str, str] | None = None  # path -> rev（上次快照）
        self.tracks: dict[str, dict] = {}           # path -> make_track 輸出 + _rev/_available
        self.playlists: dict[str, dict] = {}        # path -> raw（items/name）
        self.errors: dict[str, dict] = {}           # path -> error（message 恆空）
        self.unscanned: list[str] = []              # 上輪 §3.2-8 未掃 path（非 canonical）

    def sync(self, after_delta=None) -> dict:
        snap = self.provider.snapshot()  # 失敗 → 整輪拋錯，狀態不動（§3.2-8）
        prev = self.cursor or {}
        changes = []
        for path in sorted(set(snap) | set(prev)):
            if path not in prev:
                changes.append((path, "added", snap[path]))
            elif path not in snap:
                changes.append((path, "removed", prev[path]))
            elif snap[path] != prev[path]:
                changes.append((path, "modified", snap[path]))
        relevant = [(p, k, r) for p, k, r in changes
                    if fmt_for(p) is not None or p.lower().endswith(".m3u8")]

        pending = []
        for path, kind, rev in relevant:
            if kind == "removed":
                if path in self.tracks:
                    self.tracks[path]["_available"] = False
                self.playlists.pop(path, None)
                self.errors.pop(path, None)
            else:
                pending.append((path, rev))
        if after_delta:
            after_delta()
        scanned = []
        unscanned: list[str] = []
        for i, (path, rev) in enumerate(pending):
            try:
                data = self.provider.read_bytes(path)
            except ProviderError:
                unscanned = [p for p, _ in pending[i:]]  # §3.2-8：本輪剩餘全部續掃
                break
            if data is None:
                continue  # §3.2-4：掃描中拔檔 → 靜默丟棄
            scanned.append(path)
            if path.lower().endswith(".m3u8"):
                self.playlists[path] = parse_m3u8_raw(
                    data.decode("utf-8", "replace"), path)
                continue
            fields, tag_ok = parse_tags(fmt_for(path), data)
            if fields is None:
                self.tracks.pop(path, None)
                self.errors[path] = {"code": "BAD_CONTAINER",
                                     "message": "", "path": path}
                continue
            self.errors.pop(path, None)
            t = make_track(path, fmt_for(path), len(data), fields, tag_ok,
                           parse_duration(fmt_for(path), data))
            t["_rev"] = rev
            t["_available"] = True
            self.tracks[path] = t
        cursor = dict(snap)
        for p in unscanned:  # cursor 保留上一輪值，下輪再列為 added/modified
            if p in prev:
                cursor[p] = prev[p]
            else:
                cursor.pop(p, None)
        self.cursor = cursor
        self.unscanned = sorted(unscanned)
        return self._report(relevant, scanned)

    def _report(self, changes, scanned) -> dict:
        audio_ok = {p for p, t in self.tracks.items() if t["_available"]}
        tracks_out = []
        for p in sorted(self.tracks):
            t = dict(self.tracks[p])
            t.pop("_compilation")
            t["available"] = t.pop("_available")
            t["rev"] = t.pop("_rev")
            tracks_out.append(t)
        playlists_out = []
        for p in sorted(self.playlists):
            pl = self.playlists[p]
            base = "/".join(p.split("/")[:-1])
            items = []
            for it in pl["items"]:
                ref = it["ref"]
                tid = None
                if not ref.startswith("/"):
                    r = _norm_path(f"{base}/{ref}" if base else ref)
                    if r is not None and r in audio_ok:
                        tid = r
                items.append({"durationMs": it["durationMs"],
                              "missing": tid is None,
                              "position": it["position"],
                              "ref": ref, "trackId": tid})
            playlists_out.append({"id": p, "items": items,
                                  "name": pl["name"], "path": p})
        albums = sorted(
            group_albums([self.tracks[p] for p in sorted(self.tracks)]),
            key=lambda a: (a["albumArtist"], a["name"]))
        errors = [self.errors[p] for p in sorted(self.errors)]
        return {
            "changes": sorted(
                ({"kind": k, "path": p, "rev": r} for p, k, r in changes),
                key=lambda c: (c["path"], c["kind"])),
            "scanned": sorted(scanned),
            "index": {"albums": albums, "errors": errors,
                      "playlists": playlists_out, "tracks": tracks_out},
        }

# ---------------------------------------------------------------- driver

def apply_op(root: Path, op: dict, delete_after: list[str]):
    k = op["op"]
    if k == "write":
        p = root / op["path"]
        p.parent.mkdir(parents=True, exist_ok=True)
        data = ((ASSETS / op["asset"]).read_bytes() if "asset" in op
                else op["text"].encode("utf-8"))
        p.write_bytes(data)
        os.utime(p, (op["mtime"], op["mtime"]))
    elif k == "delete":
        (root / op["path"]).unlink()
    elif k == "rename":
        dst = root / op["to"]
        dst.parent.mkdir(parents=True, exist_ok=True)
        os.rename(root / op["from"], dst)
    elif k == "touch":
        p = root / op["path"]
        os.utime(p, (op["mtime"], op["mtime"]))
    elif k == "delete_after_delta":
        delete_after.append(op["path"])
    else:
        raise ValueError(k)

def run_case(case_dir: Path) -> list[dict]:
    script = json.loads((case_dir / "script.json").read_text(encoding="utf-8"))
    with tempfile.TemporaryDirectory() as td:
        root = Path(td) / "lib"
        root.mkdir()
        engine = SyncEngine(LocalProvider(root))
        reports = []
        for step in script["steps"]:
            delete_after: list[str] = []
            for op in step["ops"]:
                apply_op(root, op, delete_after)
            reports.append(engine.sync(
                after_delta=lambda ps=delete_after: [
                    (root / p).unlink(missing_ok=True) for p in ps]))
        return reports

# ---------------------------------------------------------------- cases

def build_scripts() -> dict[str, dict]:
    return {
        "sync_initial_scan": {"steps": [
            {"ops": [
                {"op": "write", "path": "Aurora/Northern Lights/01 - Rise.flac",
                 "asset": "flac_a", "mtime": 1700000100},
                {"op": "write", "path": "Aurora/Northern Lights/02 - Drift.flac",
                 "asset": "flac_b", "mtime": 1700000101},
                {"op": "write", "path": "Various Artists/Dream Mixtape/07 - Unknown.flac",
                 "asset": "flac_notags", "mtime": 1700000102},
                {"op": "write", "path": "Aurora/Northern Lights/cover.jpg",
                 "text": "not-a-real-jpg", "mtime": 1700000103},
                {"op": "write", "path": "Docs/readme.txt",
                 "text": "hello", "mtime": 1700000104},
            ]},
            {"ops": []},
        ]},
        "sync_add_modify_delete": {"steps": [
            {"ops": [
                {"op": "write", "path": "Aurora/Northern Lights/01 - Rise.flac",
                 "asset": "flac_a", "mtime": 1700000200},
                {"op": "write", "path": "Ken/Album One/01 - A.flac",
                 "asset": "flac_notags", "mtime": 1700000201},
            ]},
            {"ops": [
                {"op": "write", "path": "Kyary/Jelly/02 - Ninjya.mp3",
                 "asset": "mp3_tags", "mtime": 1700000300},
            ]},
            {"ops": [
                {"op": "write", "path": "Aurora/Northern Lights/01 - Rise.flac",
                 "asset": "flac_b", "mtime": 1700000400},
            ]},
            {"ops": [
                {"op": "delete", "path": "Ken/Album One/01 - A.flac"},
            ]},
            {"ops": []},
        ]},
        "sync_mtime_touch": {"steps": [
            {"ops": [
                {"op": "write", "path": "Aurora/Northern Lights/01 - Rise.flac",
                 "asset": "flac_a", "mtime": 1700000500},
            ]},
            {"ops": [
                {"op": "touch", "path": "Aurora/Northern Lights/01 - Rise.flac",
                 "mtime": 1700000900},
            ]},
            {"ops": []},
        ]},
        "sync_rename": {"steps": [
            {"ops": [
                {"op": "write", "path": "Aurora/Northern Lights/01 - Rise.flac",
                 "asset": "flac_a", "mtime": 1700000600},
            ]},
            {"ops": [
                {"op": "rename", "from": "Aurora/Northern Lights/01 - Rise.flac",
                 "to": "Aurora/Northern Lights/01 - Risen.flac"},
            ]},
            {"ops": []},
        ]},
        "sync_playlist_lifecycle": {"steps": [
            {"ops": [
                {"op": "write", "path": "Aurora/Northern Lights/01 - Rise.flac",
                 "asset": "flac_a", "mtime": 1700000700},
                {"op": "write", "path": "Playlists/best.m3u8", "mtime": 1700000701,
                 "text": "#EXTM3U\n#EXTINF:213.5,Rise\n../Aurora/Northern Lights/01 - Rise.flac\n"},
            ]},
            {"ops": [
                {"op": "write", "path": "Playlists/best.m3u8", "mtime": 1700000800,
                 "text": "#EXTM3U\n#EXTINF:213.5,Rise\n../Aurora/Northern Lights/01 - Rise.flac\n../Nowhere/02 - Ghost.flac\n"},
            ]},
            {"ops": [
                {"op": "delete", "path": "Aurora/Northern Lights/01 - Rise.flac"},
            ]},
            {"ops": [
                {"op": "delete", "path": "Playlists/best.m3u8"},
            ]},
        ]},
        "sync_scan_race": {"steps": [
            {"ops": [
                {"op": "write", "path": "Aurora/Northern Lights/01 - Rise.flac",
                 "asset": "flac_a", "mtime": 1700000850},
            ]},
            {"ops": [
                {"op": "write", "path": "Ken/Album One/01 - B.flac",
                 "asset": "flac_b", "mtime": 1700000851},
                {"op": "delete_after_delta", "path": "Ken/Album One/01 - B.flac"},
            ]},
            {"ops": []},
        ]},
    }

def main():
    if CASES.exists():
        import shutil
        shutil.rmtree(CASES)
    build_assets()
    scripts = build_scripts()
    for name, script in scripts.items():
        case = CASES / name
        case.mkdir(parents=True)
        (case / "script.json").write_text(
            json.dumps(script, indent=2, ensure_ascii=False) + "\n",
            encoding="utf-8")
        reports = run_case(case)
        (case / "expected.json").write_text(canonical(reports), encoding="utf-8")

    def report(name, step):
        return json.loads((CASES / name / "expected.json").read_text())[step]
    r = report("sync_initial_scan", 0)
    assert len(r["changes"]) == 3 and all(c["kind"] == "added" for c in r["changes"]), r["changes"]
    assert len(r["scanned"]) == 3 and len(r["index"]["tracks"]) == 3
    r = report("sync_initial_scan", 1)
    assert r["changes"] == [] and r["scanned"] == [], "rev 未變 → 跳過"
    r = report("sync_add_modify_delete", 2)
    byp = {c["path"]: c for c in r["changes"]}
    assert byp["Aurora/Northern Lights/01 - Rise.flac"]["kind"] == "modified"
    t = {t["path"]: t for t in r["index"]["tracks"]}["Aurora/Northern Lights/01 - Rise.flac"]
    assert t["title"] == "Drift", "改內容 → 重掃出新 tag"
    r = report("sync_add_modify_delete", 3)
    t = {t["path"]: t for t in r["index"]["tracks"]}["Ken/Album One/01 - A.flac"]
    assert t["available"] is False, "刪除 → unavailable 保留資料"
    r = report("sync_mtime_touch", 1)
    assert r["changes"][0]["kind"] == "modified" and len(r["scanned"]) == 1, "touch → 重掃"
    r = report("sync_rename", 1)
    kinds = sorted((c["path"], c["kind"]) for c in r["changes"])
    assert kinds == [("Aurora/Northern Lights/01 - Rise.flac", "removed"),
                     ("Aurora/Northern Lights/01 - Risen.flac", "added")], kinds
    r = report("sync_playlist_lifecycle", 2)
    assert r["index"]["playlists"][0]["items"][0]["missing"] is True, \
        "音訊 unavailable → 清單解析自動 missing"
    r = report("sync_scan_race", 1)
    assert {c["path"]: c["kind"] for c in r["changes"]}.get(
        "Ken/Album One/01 - B.flac") == "added"
    assert "Ken/Album One/01 - B.flac" not in r["scanned"], "拔檔 → 不掃"
    assert all(t["path"] != "Ken/Album One/01 - B.flac"
               for t in r["index"]["tracks"]), "拔檔 → 不進索引"
    r = report("sync_scan_race", 2)
    assert {c["path"]: c["kind"] for c in r["changes"]}.get(
        "Ken/Album One/01 - B.flac") == "removed", "下輪 delta 補 removed"
    print(f"OK: {len(scripts)} sync cases generated, all sanity asserts passed")

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
        print(f"DRIFT: {len(bad)} sync case(s) differ: {', '.join(bad)}")
        return 1
    print("OK: all sync cases byte-identical to expected.json")
    return 0

def update_expected() -> int:
    """重放 script 改寫 expected.json（資產池 committed，不跑 ffmpeg）。"""
    for case in sorted(CASES.iterdir()):
        if case.is_dir():
            (case / "expected.json").write_text(canonical(run_case(case)),
                                                encoding="utf-8")
    print("OK: all sync expected.json updated")
    return 0

if __name__ == "__main__":
    if sys.argv[1:] == ["--check"]:
        sys.exit(check())
    if sys.argv[1:] == ["--update-expected"]:
        sys.exit(update_expected())
    main()
