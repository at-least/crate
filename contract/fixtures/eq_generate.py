#!/usr/bin/env python3
"""
Crate EQ / 播放增益契約 fixtures 產生器（兼 Python 參考實作）

- model.md §1.10：EqSettings（10 段 millibel + preamp + presets）與播放總增益合成規則
- 純整數（浮點 DSP 不入 byte 比對——各平台以 Biquad 單元測試驗證頻率響應）
- 產出 eq_cases/<name>/script.json + expected.json

重跑：python3 eq_generate.py          （重寫 script + expected）
驗證：python3 eq_generate.py --check  （重放比對 expected；可進 CI）
"""
import json, sys
from pathlib import Path

from generate import canonical

HERE = Path(__file__).parent
CASES = HERE / "eq_cases"

BAND_HZ = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
BAND_Q = 1.41
GAIN_LIMIT_MB = 1200          # 每段與 preamp 的 clamp
RG_LIMIT_MB = 6000            # ReplayGain 部分的 clamp
TOTAL_MIN_MB, TOTAL_MAX_MB = -6000, 1200

PRESETS: dict[str, list[int]] = {
    "flat": [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    "rock": [500, 400, 200, 0, -100, -100, 200, 400, 500, 500],
    "pop": [-100, 100, 300, 400, 300, 100, 0, -100, -100, -100],
    "jazz": [300, 200, 100, 200, -100, -100, 0, 100, 200, 300],
    "classical": [400, 300, 200, 100, -100, -100, 0, 200, 300, 400],
    "bass": [700, 600, 400, 200, 0, 0, 0, 0, 0, 0],
    "treble": [0, 0, 0, 0, 0, 100, 300, 500, 600, 700],
    "vocal": [-200, -100, 0, 200, 400, 400, 300, 100, 0, -100],
    "loudness": [600, 500, 200, 0, -200, -200, 0, 200, 500, 600],
}


def clamp(v: int, lo: int, hi: int) -> int:
    return lo if v < lo else (hi if v > hi else v)


class EqSettings:
    """model.md §1.10。bands 恆 10 段、各值已 clamp。"""

    def __init__(self, bands: list[int] | None = None, enabled: bool = False,
                 preamp: int = 0, preset: str = "flat"):
        b = list(bands or [])[:len(BAND_HZ)]
        b += [0] * (len(BAND_HZ) - len(b))
        self.bands = [clamp(x, -GAIN_LIMIT_MB, GAIN_LIMIT_MB) for x in b]
        self.enabled = bool(enabled)
        self.preamp = clamp(int(preamp), -GAIN_LIMIT_MB, GAIN_LIMIT_MB)
        self.preset = preset

    @staticmethod
    def default() -> "EqSettings":
        return EqSettings()

    @staticmethod
    def preset_named(name: str, enabled: bool = True, preamp: int = 0) -> "EqSettings":
        return EqSettings(PRESETS.get(name, PRESETS["flat"]), enabled, preamp,
                          name if name in PRESETS else "flat")

    @staticmethod
    def parse(text: str | None) -> "EqSettings":
        """壞 JSON / 缺鍵 → 預設；非整數 band → 0。"""
        if not text:
            return EqSettings.default()
        try:
            obj = json.loads(text)
        except Exception:
            return EqSettings.default()
        if not isinstance(obj, dict):
            return EqSettings.default()
        raw = obj.get("bands")
        bands = []
        if isinstance(raw, list):
            for v in raw:
                bands.append(v if isinstance(v, int) and not isinstance(v, bool) else 0)
        preamp = obj.get("preamp")
        preset = obj.get("preset")
        return EqSettings(
            bands,
            obj.get("enabled") is True,
            preamp if isinstance(preamp, int) and not isinstance(preamp, bool) else 0,
            preset if isinstance(preset, str) and preset in PRESETS else "flat",
        )

    def to_json(self) -> dict:
        return {"bands": list(self.bands), "enabled": self.enabled,
                "preamp": self.preamp, "preset": self.preset}

    def serialize(self) -> str:
        return json.dumps(self.to_json(), sort_keys=True, separators=(",", ":"))

    def active_bands(self) -> list[tuple[int, int]]:
        """(頻率, mb)；停用或增益 0 的段不進 DSP。"""
        if not self.enabled:
            return []
        return [(f, mb) for f, mb in zip(BAND_HZ, self.bands) if mb != 0]

    def is_identity(self, gain_mb: int) -> bool:
        """DSP 直通判定（§1.10 末段）。"""
        return gain_mb == 0 and not self.active_bands()


def rg_gain_mb(mode: str, track_mb: int | None, album_mb: int | None) -> int | None:
    """model.md §1.9 消費端。"""
    if mode == "off":
        return None
    if mode == "track":
        return track_mb
    return album_mb if album_mb is not None else track_mb


def playback_gain_mb(mode: str, track_mb: int | None, album_mb: int | None,
                     eq: EqSettings) -> int:
    rg = rg_gain_mb(mode, track_mb, album_mb)
    total = clamp(rg if rg is not None else 0, -RG_LIMIT_MB, RG_LIMIT_MB)
    if eq.enabled:
        total += eq.preamp
    return clamp(total, TOTAL_MIN_MB, TOTAL_MAX_MB)


# ---------------------------------------------------------------- driver

def run_case(case_dir: Path) -> list[dict]:
    script = json.loads((case_dir / "script.json").read_text(encoding="utf-8"))
    out = []
    for entry in script["entries"]:
        kind = entry["type"]
        if kind == "parse":
            eq = EqSettings.parse(entry["text"])
            out.append({"kind": kind, "name": entry["name"],
                        "settings": eq.to_json(), "serialized": eq.serialize(),
                        "activeBands": [list(x) for x in eq.active_bands()]})
        elif kind == "preset":
            eq = EqSettings.preset_named(entry["name"], entry.get("enabled", True),
                                         entry.get("preamp", 0))
            out.append({"kind": kind, "name": entry["name"],
                        "settings": eq.to_json(), "serialized": eq.serialize(),
                        "activeBands": [list(x) for x in eq.active_bands()]})
        elif kind == "gain":
            eq = EqSettings.parse(entry.get("eq"))
            gain = playback_gain_mb(entry["mode"], entry.get("trackMb"),
                                    entry.get("albumMb"), eq)
            out.append({"kind": kind, "name": entry["name"], "gainMb": gain,
                        "identity": eq.is_identity(gain)})
        else:
            raise ValueError(kind)
    return out


def build_scripts() -> dict[str, dict]:
    def eqj(**kw) -> str:
        return json.dumps(kw)

    return {
        "eq_settings": {"entries": [
            {"type": "parse", "name": "empty", "text": ""},
            {"type": "parse", "name": "null", "text": None},
            {"type": "parse", "name": "garbage", "text": "{not json"},
            {"type": "parse", "name": "not_object", "text": "[1,2,3]"},
            {"type": "parse", "name": "full",
             "text": eqj(bands=[100, -200, 0, 0, 0, 0, 0, 0, 0, 300], enabled=True,
                         preamp=-150, preset="rock")},
            {"type": "parse", "name": "clamped",
             "text": eqj(bands=[9999, -9999, 0, 0, 0, 0, 0, 0, 0, 0], enabled=True,
                         preamp=5000, preset="flat")},
            {"type": "parse", "name": "short_bands",
             "text": eqj(bands=[100, 200], enabled=True)},
            {"type": "parse", "name": "long_bands",
             "text": eqj(bands=[100] * 14, enabled=True)},
            {"type": "parse", "name": "bad_types",
             "text": eqj(bands=[100, "x", None, 1.5, True, 0, 0, 0, 0, 0],
                         enabled="yes", preamp="3", preset="nope")},
            {"type": "parse", "name": "unknown_keys",
             "text": eqj(bands=[0] * 10, enabled=True, preamp=0, preset="jazz", extra=1)},
        ]},
        "eq_presets": {"entries": (
            [{"type": "preset", "name": n} for n in sorted(PRESETS)] +
            [{"type": "preset", "name": "unknown_name"},
             {"type": "preset", "name": "bass", "enabled": False},
             {"type": "preset", "name": "rock", "preamp": -300}]
        )},
        "eq_playback_gain": {"entries": [
            {"type": "gain", "name": "off_no_eq", "mode": "off",
             "trackMb": -654, "albumMb": 210},
            {"type": "gain", "name": "track", "mode": "track",
             "trackMb": -654, "albumMb": 210},
            {"type": "gain", "name": "album", "mode": "album",
             "trackMb": -654, "albumMb": 210},
            {"type": "gain", "name": "album_falls_back", "mode": "album",
             "trackMb": -654, "albumMb": None},
            {"type": "gain", "name": "no_tags", "mode": "album",
             "trackMb": None, "albumMb": None},
            {"type": "gain", "name": "preamp_disabled_eq", "mode": "off",
             "eq": json.dumps({"bands": [0] * 10, "enabled": False, "preamp": 600})},
            {"type": "gain", "name": "preamp_enabled_eq", "mode": "off",
             "eq": json.dumps({"bands": [0] * 10, "enabled": True, "preamp": 600})},
            {"type": "gain", "name": "positive_total_clamped", "mode": "track",
             "trackMb": 1000,
             "eq": json.dumps({"bands": [0] * 10, "enabled": True, "preamp": 1200})},
            {"type": "gain", "name": "negative_total_clamped", "mode": "track",
             "trackMb": -9000,
             "eq": json.dumps({"bands": [0] * 10, "enabled": True, "preamp": -1200})},
            {"type": "gain", "name": "identity_when_flat_and_zero", "mode": "off",
             "eq": json.dumps({"bands": [0] * 10, "enabled": True, "preamp": 0})},
            {"type": "gain", "name": "not_identity_with_band", "mode": "off",
             "eq": json.dumps({"bands": [0, 0, 0, 0, 0, 0, 0, 0, 0, 200], "enabled": True})},
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

    r = rows("eq_settings")
    assert r["empty"]["settings"] == {"bands": [0] * 10, "enabled": False,
                                      "preamp": 0, "preset": "flat"}
    assert r["garbage"]["settings"]["enabled"] is False
    assert r["clamped"]["settings"]["bands"][:2] == [1200, -1200]
    assert r["clamped"]["settings"]["preamp"] == 1200
    assert len(r["short_bands"]["settings"]["bands"]) == 10
    assert len(r["long_bands"]["settings"]["bands"]) == 10
    assert r["bad_types"]["settings"]["bands"] == [100, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    assert r["bad_types"]["settings"]["enabled"] is False and r["bad_types"]["settings"]["preamp"] == 0
    assert r["bad_types"]["settings"]["preset"] == "flat"
    assert r["unknown_keys"]["settings"]["preset"] == "jazz"
    assert r["full"]["activeBands"] == [[31, 100], [62, -200], [16000, 300]]

    r = rows("eq_presets")
    assert r["rock"]["settings"]["bands"] == PRESETS["rock"]
    assert r["unknown_name"]["settings"]["bands"] == PRESETS["flat"]
    assert r["unknown_name"]["settings"]["preset"] == "flat"
    assert r["bass"]["activeBands"] == [], "enabled=False → 無 active band"
    assert r["flat"]["activeBands"] == []

    r = rows("eq_playback_gain")
    assert r["off_no_eq"]["gainMb"] == 0
    assert r["track"]["gainMb"] == -654
    assert r["album"]["gainMb"] == 210
    assert r["album_falls_back"]["gainMb"] == -654
    assert r["no_tags"]["gainMb"] == 0
    assert r["preamp_disabled_eq"]["gainMb"] == 0
    assert r["preamp_enabled_eq"]["gainMb"] == 600
    assert r["positive_total_clamped"]["gainMb"] == 1200, "總增益上限 +12 dB"
    assert r["negative_total_clamped"]["gainMb"] == -6000
    assert r["identity_when_flat_and_zero"]["identity"] is True
    assert r["not_identity_with_band"]["identity"] is False
    print(f"OK: {len(scripts)} eq cases generated, all sanity asserts passed")


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
        print(f"DRIFT: {len(bad)} eq case(s) differ: {', '.join(bad)}")
        return 1
    print("OK: all eq cases byte-identical to expected.json")
    return 0


if __name__ == "__main__":
    if sys.argv[1:] == ["--check"]:
        sys.exit(check())
    main()
