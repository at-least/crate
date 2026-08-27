#!/usr/bin/env python3
"""
Mu 錯誤語意契約 fixtures 產生器（兼 Python 參考實作）

- provider.md §2.1：重試政策 + FakeProvider putText 衝突
- 產出 err_cases/<name>/script.json + expected.json（時脈注入，純確定性，無 ffmpeg）
- 三實作 byte-identical（本檔 / Kotlin ErrFixtureTest / Swift ErrFixtureTest）

重跑：python3 err_generate.py         （重寫 script + expected；無外部依賴）
驗證：python3 err_generate.py --check （重放比對 expected）
"""
import json, sys
from pathlib import Path

from generate import canonical

HERE = Path(__file__).parent
CASES = HERE / "err_cases"

TRANSIENT_DELAYS = [1000, 2000, 4000, 8000, 16000]
MAX_TRANSIENT_RETRIES = 5

# ---------------------------------------------------------------- 參考實作

class RetryPolicy:
    """provider.md §2.1。sleeps 收集實際延遲（時脈注入）。"""

    def run(self, script: list[str], on_reauth) -> dict:
        sleeps: list[int] = []
        transient = 0
        reauth_used = False
        reauths = 0
        queue = list(script)
        while True:
            err = queue.pop(0) if queue else "ok"
            if err == "ok":
                return {"reauths": reauths, "result": "ok", "sleeps": sleeps}
            if err in ("notfound", "conflict"):
                return {"reauths": reauths, "result": err, "sleeps": sleeps}
            if err == "auth":
                if reauth_used:
                    return {"reauths": reauths, "result": "auth", "sleeps": sleeps}
                reauth_used = True
                reauths += 1
                on_reauth()
                continue
            if err == "transient":
                if transient >= MAX_TRANSIENT_RETRIES:
                    return {"reauths": reauths, "result": "transient", "sleeps": sleeps}
                sleeps.append(TRANSIENT_DELAYS[transient])
                transient += 1
                continue
            raise ValueError(err)

class FakeFiles:
    """FakeProvider 的檔案面：rev = 遞增整數字串。"""

    def __init__(self):
        self.files: dict[str, tuple[str, str]] = {}
        self.seq = 0

    def _next_rev(self) -> str:
        self.seq += 1
        return str(self.seq)

    def seed(self, path: str, text: str) -> str:
        r = self._next_rev()
        self.files[path] = (text, r)
        return r

    def current_rev(self, path: str) -> str | None:
        t = self.files.get(path)
        return t[1] if t else None

    def put_text(self, path: str, text: str, parent_rev: str | None) -> dict:
        cur = self.files.get(path)
        if parent_rev is not None and (cur is None or cur[1] != parent_rev):
            return {"error": "conflict", "ok": False, "rev": None}
        r = self._next_rev()
        self.files[path] = (text, r)
        return {"error": None, "ok": True, "rev": r}

# ---------------------------------------------------------------- cases

def build() -> dict[str, dict]:
    return {
        "retry_and_conflict": {"entries": [
            # §2.1 重試政策
            {"type": "retry", "name": "backoff_then_ok",
             "script": ["transient", "transient", "ok"]},
            {"type": "retry", "name": "backoff_exhaust",
             "script": ["transient"] * 6},
            {"type": "retry", "name": "auth_once",
             "script": ["auth", "ok"]},
            {"type": "retry", "name": "auth_twice_fails",
             "script": ["auth", "auth"]},
            {"type": "retry", "name": "notfound_no_retry",
             "script": ["notfound"]},
            {"type": "retry", "name": "conflict_no_retry",
             "script": ["conflict"]},
            {"type": "retry", "name": "mixed_transient_then_auth",
             "script": ["transient", "auth", "ok"]},
            {"type": "retry", "name": "auth_then_transient_exhaust",
             "script": ["auth"] + ["transient"] * 6},
            # putText 衝突（FakeFiles）
            {"type": "put", "name": "put_lifecycle", "ops": [
                {"op": "seed", "path": "Playlists/a.m3u8", "text": "v1"},
                {"op": "put", "path": "Playlists/a.m3u8", "text": "v2-me",
                 "parentRev": "1"},
                {"op": "remote", "path": "Playlists/a.m3u8", "text": "v2-other"},
                {"op": "put", "path": "Playlists/a.m3u8", "text": "v3-me",
                 "parentRev": "1"},
                {"op": "put", "path": "Playlists/a.m3u8", "text": "v3",
                 "parentRev": None},
                {"op": "put", "path": "Playlists/b.m3u8", "text": "new",
                 "parentRev": "9"},
            ]},
        ]},
    }

def run_script(case: dict) -> list[dict]:
    out = []
    policy = RetryPolicy()
    files = FakeFiles()
    for e in case["entries"]:
        if e["type"] == "retry":
            out.append(policy.run(e["script"], on_reauth=lambda: None))
        else:
            for op in e["ops"]:
                if op["op"] == "seed":
                    files.seed(op["path"], op["text"])
                elif op["op"] == "remote":
                    files.seed(op["path"], op["text"])
                elif op["op"] == "put":
                    out.append(files.put_text(
                        op["path"], op["text"], op.get("parentRev")))
    return out

def main():
    if CASES.exists():
        import shutil
        shutil.rmtree(CASES)
    for name, case in build().items():
        d = CASES / name
        d.mkdir(parents=True)
        (d / "script.json").write_text(
            json.dumps(case, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        (d / "expected.json").write_text(canonical(run_script(case)), encoding="utf-8")

    # sanity asserts
    r = json.loads((CASES / "retry_and_conflict" / "expected.json").read_text())
    by = {e.get("name"): e for e in build()["retry_and_conflict"]["entries"]}
    def at(n): return r[[e["name"] for e in by.values()].index(n)]
    assert at("backoff_then_ok") == {"reauths": 0, "result": "ok", "sleeps": [1000, 2000]}
    assert at("backoff_exhaust")["sleeps"] == TRANSIENT_DELAYS
    assert at("backoff_exhaust")["result"] == "transient"
    assert at("auth_once") == {"reauths": 1, "result": "ok", "sleeps": []}
    assert at("auth_twice_fails")["result"] == "auth"
    assert at("notfound_no_retry")["sleeps"] == []
    assert at("mixed_transient_then_auth") == {"reauths": 1, "result": "ok", "sleeps": [1000]}
    puts = r[-4:]
    assert puts[0] == {"error": None, "ok": True, "rev": "2"}   # seed 後 parentRev 吻合
    assert puts[1] == {"error": "conflict", "ok": False, "rev": None}  # 遠端已改
    assert puts[2] == {"error": None, "ok": True, "rev": "4"}    # parentRev=None 蓋寫
    assert puts[3] == {"error": "conflict", "ok": False, "rev": None}  # 不存在+帶 parentRev
    print("OK: err_cases generated, sanity asserts passed")

def check() -> int:
    bad = []
    for case_dir in sorted(CASES.iterdir()):
        if not case_dir.is_dir():
            continue
        case = json.loads((case_dir / "script.json").read_text(encoding="utf-8"))
        actual = canonical(run_script(case))
        expected_path = case_dir / "expected.json"
        if not expected_path.exists() or \
                expected_path.read_text(encoding="utf-8") != actual:
            bad.append(case_dir.name)
    if bad:
        print(f"DRIFT: {', '.join(bad)}")
        return 1
    print("OK: all err cases byte-identical to expected.json")
    return 0

if __name__ == "__main__":
    if sys.argv[1:] == ["--check"]:
        sys.exit(check())
    main()
