#!/usr/bin/env python3
"""
Crate 錯誤語意契約 fixtures 產生器（兼 Python 參考實作）

- provider.md §2.1：重試政策（D12 後唯讀定位，僅 auth/transient/notfound 三種）
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
            if err == "notfound":
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

# ---------------------------------------------------------------- cases

def build() -> dict[str, dict]:
    return {
        "retry": {"entries": [
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
            {"type": "retry", "name": "mixed_transient_then_auth",
             "script": ["transient", "auth", "ok"]},
            {"type": "retry", "name": "auth_then_transient_exhaust",
             "script": ["auth"] + ["transient"] * 6},
        ]},
    }

def run_script(case: dict) -> list[dict]:
    out = []
    policy = RetryPolicy()
    for e in case["entries"]:
        out.append(policy.run(e["script"], on_reauth=lambda: None))
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
    r = json.loads((CASES / "retry" / "expected.json").read_text())
    by = {e["name"]: e for e in build()["retry"]["entries"]}
    def at(n): return r[[e["name"] for e in by.values()].index(n)]
    assert at("backoff_then_ok") == {"reauths": 0, "result": "ok", "sleeps": [1000, 2000]}
    assert at("backoff_exhaust")["sleeps"] == TRANSIENT_DELAYS
    assert at("backoff_exhaust")["result"] == "transient"
    assert at("auth_once") == {"reauths": 1, "result": "ok", "sleeps": []}
    assert at("auth_twice_fails")["result"] == "auth"
    assert at("notfound_no_retry")["sleeps"] == []
    assert at("mixed_transient_then_auth") == {"reauths": 1, "result": "ok", "sleeps": [1000]}
    assert at("auth_then_transient_exhaust")["result"] == "transient"
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
    # 未知參數一律退出，**不**掉進會重寫 fixtures 的 main()（同 generate.py）。
    args = sys.argv[1:]
    if args == ["--check"]:
        sys.exit(check())
    elif args:
        sys.exit(f"未知參數：{' '.join(args)}\n"
                 f"用法：python3 {__file__.split('/')[-1]} [--check]"
                 f"（無參數 = 重新產生，會覆寫 fixtures）")
    main()
