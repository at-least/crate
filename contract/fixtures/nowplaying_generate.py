#!/usr/bin/env python3
"""
Crate 現正播放快照契約 fixtures 產生器（兼 Python 參考實作）

- model.md §1.11：NowPlayingSnapshot（序列化/解析、displayState、effectivePositionMs）
- 純整數/字串（Widget 顯示邏輯的可測部分）
- 產出 nowplaying_cases/<name>/script.json + expected.json

重跑：python3 nowplaying_generate.py          （重寫 script + expected）
驗證：python3 nowplaying_generate.py --check  （重放比對 expected；可進 CI）
"""
import json, sys
from pathlib import Path

from generate import canonical

HERE = Path(__file__).parent
CASES = HERE / "nowplaying_cases"

STALE_AFTER_MS = 6 * 60 * 60 * 1000  # 6 小時


class NowPlayingSnapshot:
    """model.md §1.11。"""

    def __init__(self, track_id: str | None = None, title: str | None = None,
                 artist: str | None = None, album_id: str | None = None,
                 is_playing: bool = False, position_ms: int = 0,
                 duration_ms: int | None = None, updated_at_ms: int = 0):
        self.track_id = track_id or None
        self.title = title or None
        self.artist = artist or None
        self.album_id = album_id or None
        self.is_playing = bool(is_playing)
        self.position_ms = max(0, int(position_ms))
        self.duration_ms = None if duration_ms is None else max(0, int(duration_ms))
        self.updated_at_ms = int(updated_at_ms)

    @staticmethod
    def idle() -> "NowPlayingSnapshot":
        return NowPlayingSnapshot()

    @staticmethod
    def parse(text: str | None) -> "NowPlayingSnapshot":
        if not text:
            return NowPlayingSnapshot.idle()
        try:
            obj = json.loads(text)
        except Exception:
            return NowPlayingSnapshot.idle()
        if not isinstance(obj, dict):
            return NowPlayingSnapshot.idle()

        def s(key: str) -> str | None:
            v = obj.get(key)
            return v if isinstance(v, str) and v else None

        def i(key: str, default: int | None = 0) -> int | None:
            v = obj.get(key)
            return v if isinstance(v, int) and not isinstance(v, bool) else default

        return NowPlayingSnapshot(
            track_id=s("trackId"), title=s("title"), artist=s("artist"),
            album_id=s("albumId"), is_playing=obj.get("isPlaying") is True,
            position_ms=i("positionMs") or 0, duration_ms=i("durationMs", None),
            updated_at_ms=i("updatedAtMs") or 0)

    def to_json(self) -> dict:
        return {"albumId": self.album_id, "artist": self.artist,
                "durationMs": self.duration_ms, "isPlaying": self.is_playing,
                "positionMs": self.position_ms, "title": self.title,
                "trackId": self.track_id, "updatedAtMs": self.updated_at_ms}

    def serialize(self) -> str:
        return json.dumps(self.to_json(), sort_keys=True, separators=(",", ":"))

    def display_state(self, now_ms: int, stale_after_ms: int = STALE_AFTER_MS) -> str:
        if self.track_id is None:
            return "idle"
        if now_ms - self.updated_at_ms > stale_after_ms:
            return "idle"
        return "playing" if self.is_playing else "paused"

    def effective_position_ms(self, now_ms: int, stale_after_ms: int = STALE_AFTER_MS) -> int:
        if self.display_state(now_ms, stale_after_ms) != "playing":
            return max(0, self.position_ms)
        pos = self.position_ms + max(0, now_ms - self.updated_at_ms)
        if self.duration_ms is not None:
            pos = min(pos, self.duration_ms)
        return max(0, pos)


# ---------------------------------------------------------------- driver

def run_case(case_dir: Path) -> list[dict]:
    script = json.loads((case_dir / "script.json").read_text(encoding="utf-8"))
    out = []
    for e in script["entries"]:
        snap = NowPlayingSnapshot.parse(e.get("text"))
        row = {"name": e["name"], "serialized": snap.serialize(), "snapshot": snap.to_json()}
        if "nowMs" in e:
            now = e["nowMs"]
            row["displayState"] = snap.display_state(now)
            row["effectivePositionMs"] = snap.effective_position_ms(now)
        out.append(row)
    return out


def build_scripts() -> dict[str, dict]:
    base = {"albumId": "alb|Aurora|Northern Lights", "artist": "Aurora",
            "durationMs": 213000, "isPlaying": True, "positionMs": 42000,
            "title": "Rise", "trackId": "Aurora/Northern Lights/01 - Rise.flac",
            "updatedAtMs": 1700000000000}

    def with_(**kw) -> str:
        d = dict(base)
        d.update(kw)
        return json.dumps(d)

    return {
        "nowplaying_parse": {"entries": [
            {"name": "empty", "text": ""},
            {"name": "null", "text": None},
            {"name": "garbage", "text": "{not json"},
            {"name": "not_object", "text": "[1,2]"},
            {"name": "full", "text": json.dumps(base)},
            {"name": "unknown_keys", "text": with_(extra=1, artwork="x.jpg")},
            {"name": "empty_track_id", "text": with_(trackId="")},
            {"name": "missing_duration", "text": json.dumps(
                {k: v for k, v in base.items() if k != "durationMs"})},
            {"name": "bad_types", "text": json.dumps(
                {"trackId": 5, "title": None, "artist": True, "albumId": [],
                 "isPlaying": "yes", "positionMs": "1", "durationMs": 1.5,
                 "updatedAtMs": None})},
            {"name": "negative_numbers", "text": with_(positionMs=-500, durationMs=-1)},
        ]},
        "nowplaying_display": {"entries": [
            {"name": "playing_now", "text": json.dumps(base), "nowMs": 1700000000000},
            {"name": "playing_advanced", "text": json.dumps(base), "nowMs": 1700000010000},
            {"name": "playing_clamped_to_duration", "text": json.dumps(base),
             "nowMs": 1700000400000},
            {"name": "paused_keeps_position", "text": with_(isPlaying=False),
             "nowMs": 1700000010000},
            {"name": "clock_went_backwards", "text": json.dumps(base), "nowMs": 1699999990000},
            {"name": "stale_exactly_at_limit", "text": json.dumps(base),
             "nowMs": 1700000000000 + 21600000},
            {"name": "stale_past_limit", "text": json.dumps(base),
             "nowMs": 1700000000000 + 21600001},
            {"name": "idle_no_track", "text": "", "nowMs": 1700000000000},
            {"name": "no_duration_unbounded", "text": json.dumps(
                {k: v for k, v in base.items() if k != "durationMs"}), "nowMs": 1700000400000},
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

    def rows(name):
        return {r["name"]: r for r in json.loads((CASES / name / "expected.json").read_text())}

    r = rows("nowplaying_parse")
    assert r["empty"]["snapshot"]["trackId"] is None
    assert r["garbage"]["snapshot"] == r["empty"]["snapshot"]
    assert r["full"]["snapshot"]["title"] == "Rise"
    assert r["unknown_keys"]["snapshot"]["title"] == "Rise", "多餘鍵忽略"
    assert r["empty_track_id"]["snapshot"]["trackId"] is None, "空字串 = null"
    assert r["missing_duration"]["snapshot"]["durationMs"] is None
    b = r["bad_types"]["snapshot"]
    assert b == {"albumId": None, "artist": None, "durationMs": None, "isPlaying": False,
                 "positionMs": 0, "title": None, "trackId": None, "updatedAtMs": 0}, b
    assert r["negative_numbers"]["snapshot"]["positionMs"] == 0
    assert r["negative_numbers"]["snapshot"]["durationMs"] == 0

    r = rows("nowplaying_display")
    assert r["playing_now"]["displayState"] == "playing"
    assert r["playing_now"]["effectivePositionMs"] == 42000
    assert r["playing_advanced"]["effectivePositionMs"] == 52000
    assert r["playing_clamped_to_duration"]["effectivePositionMs"] == 213000, "clamp 到時長"
    assert r["paused_keeps_position"]["displayState"] == "paused"
    assert r["paused_keeps_position"]["effectivePositionMs"] == 42000
    assert r["clock_went_backwards"]["displayState"] == "playing"
    assert r["clock_went_backwards"]["effectivePositionMs"] == 42000, "時鐘回退不倒退位置"
    assert r["stale_exactly_at_limit"]["displayState"] == "playing", "剛好 6 小時仍有效"
    assert r["stale_past_limit"]["displayState"] == "idle"
    assert r["idle_no_track"]["displayState"] == "idle"
    assert r["no_duration_unbounded"]["effectivePositionMs"] == 442000, "無時長 → 不 clamp"
    print(f"OK: {len(scripts)} nowplaying cases generated, all sanity asserts passed")


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
        print(f"DRIFT: {len(bad)} nowplaying case(s) differ: {', '.join(bad)}")
        return 1
    print("OK: all nowplaying cases byte-identical to expected.json")
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
