#!/usr/bin/env python3
"""
Crate OAuth + PKCE 契約 fixtures 產生器（兼 Python 參考實作）

- provider.md §10：PKCE challenge、授權 URL 組裝、回呼解析、token 交換/更新表單、
  回應解析（TokenState）、過期判定、token 端點錯誤語意
- 純字串/整數（亂數與時脈注入）→ 三方 byte-identical
- 產出 oauth_cases/<name>/script.json + expected.json

重跑：python3 oauth_generate.py          （重寫 script + expected）
驗證：python3 oauth_generate.py --check  （重放比對 expected；可進 CI）
"""
import base64, hashlib, json, sys
from pathlib import Path

from generate import canonical

HERE = Path(__file__).parent
CASES = HERE / "oauth_cases"

UNRESERVED = set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
DEFAULT_SKEW_MS = 60_000

CONFIGS = {
    "gdrive": {
        "authorizeUrl": "https://accounts.google.com/o/oauth2/v2/auth",
        "tokenUrl": "https://oauth2.googleapis.com/token",
        "scope": "https://www.googleapis.com/auth/drive.readonly",
        "extra": [("access_type", "offline"), ("prompt", "consent")],
    },
    "dropbox": {
        "authorizeUrl": "https://www.dropbox.com/oauth2/authorize",
        "tokenUrl": "https://api.dropboxapi.com/oauth2/token",
        "scope": "files.metadata.read files.content.read",
        "extra": [("token_access_type", "offline")],
    },
}


def pct(s: str) -> str:
    """§10.2 百分比編碼：未保留字元原樣，其餘 %XX（大寫）。"""
    out = []
    for b in s.encode("utf-8"):
        c = chr(b)
        out.append(c if c in UNRESERVED else f"%{b:02X}")
    return "".join(out)


def code_challenge(verifier: str) -> str:
    digest = hashlib.sha256(verifier.encode("ascii")).digest()
    return base64.urlsafe_b64encode(digest).decode("ascii").rstrip("=")


def authorization_url(provider: str, client_id: str, redirect_uri: str,
                      verifier: str, state: str) -> str:
    cfg = CONFIGS[provider]
    params = [
        ("client_id", client_id),
        ("code_challenge", code_challenge(verifier)),
        ("code_challenge_method", "S256"),
        ("redirect_uri", redirect_uri),
        ("response_type", "code"),
        ("scope", cfg["scope"]),
        ("state", state),
    ] + cfg["extra"]
    query = "&".join(f"{pct(k)}={pct(v)}" for k, v in params)
    return f"{cfg['authorizeUrl']}?{query}"


def parse_redirect(url: str, expected_state: str) -> dict:
    """→ {status: ok|denied|state_mismatch|invalid, code?, error?}"""
    if "?" not in url:
        return {"status": "invalid"}
    query = url.split("?", 1)[1].split("#", 1)[0]
    params: dict[str, str] = {}
    for part in query.split("&"):
        if not part:
            continue
        k, _, v = part.partition("=")
        params.setdefault(unpct(k), unpct(v))
    if "error" in params:
        if params.get("state", "") != expected_state:
            return {"status": "state_mismatch"}
        return {"status": "denied", "error": params["error"]}
    if "code" not in params:
        return {"status": "invalid"}
    if params.get("state", "") != expected_state:
        return {"status": "state_mismatch"}
    return {"status": "ok", "code": params["code"]}


def unpct(s: str) -> str:
    out = bytearray()
    i = 0
    while i < len(s):
        c = s[i]
        if c == "%" and i + 2 < len(s) + 1:
            try:
                out.append(int(s[i + 1:i + 3], 16))
                i += 3
                continue
            except ValueError:
                pass
        out.append(ord(c))
        i += 1
    return out.decode("utf-8", "replace")


def form(pairs: list[tuple[str, str]]) -> str:
    return "&".join(f"{pct(k)}={pct(v)}" for k, v in pairs)


def exchange_form(client_id: str, code: str, verifier: str, redirect_uri: str) -> str:
    return form([("client_id", client_id), ("code", code), ("code_verifier", verifier),
                 ("grant_type", "authorization_code"), ("redirect_uri", redirect_uri)])


def refresh_form(client_id: str, refresh_token: str) -> str:
    return form([("client_id", client_id), ("grant_type", "refresh_token"),
                 ("refresh_token", refresh_token)])


class TokenState:
    def __init__(self, access_token: str = "", refresh_token: str = "",
                 expires_at_ms: int = 0, scope: str = ""):
        self.access_token = access_token
        self.refresh_token = refresh_token
        self.expires_at_ms = expires_at_ms
        self.scope = scope

    def to_json(self) -> dict:
        return {"accessToken": self.access_token, "expiresAtMs": self.expires_at_ms,
                "refreshToken": self.refresh_token, "scope": self.scope}

    def serialize(self) -> str:
        return json.dumps(self.to_json(), sort_keys=True, separators=(",", ":"))

    @staticmethod
    def parse(text: str | None) -> "TokenState":
        if not text:
            return TokenState()
        try:
            obj = json.loads(text)
        except Exception:
            return TokenState()
        if not isinstance(obj, dict):
            return TokenState()

        def s(k):
            v = obj.get(k)
            return v if isinstance(v, str) else ""

        exp = obj.get("expiresAtMs")
        return TokenState(s("accessToken"), s("refreshToken"),
                          exp if isinstance(exp, int) and not isinstance(exp, bool) else 0,
                          s("scope"))

    def needs_refresh(self, now_ms: int, skew_ms: int = DEFAULT_SKEW_MS) -> bool:
        return now_ms + skew_ms >= self.expires_at_ms

    def is_usable(self, now_ms: int, skew_ms: int = DEFAULT_SKEW_MS) -> bool:
        return bool(self.access_token) and not self.needs_refresh(now_ms, skew_ms)


def apply_token_response(prev: TokenState, body: str, now_ms: int) -> TokenState:
    """§10.3：expires_in 缺 → 立即過期；回應無 refresh_token → 沿用既有。"""
    try:
        obj = json.loads(body)
    except Exception:
        obj = {}
    if not isinstance(obj, dict):
        obj = {}

    def s(k, default=""):
        v = obj.get(k)
        return v if isinstance(v, str) else default

    expires_in = obj.get("expires_in")
    if isinstance(expires_in, str) and expires_in.isdigit():
        expires_in = int(expires_in)
    if not isinstance(expires_in, int) or isinstance(expires_in, bool):
        expires_in = 0
    return TokenState(
        access_token=s("access_token", prev.access_token),
        refresh_token=s("refresh_token", prev.refresh_token),
        expires_at_ms=now_ms + expires_in * 1000,
        scope=s("scope", prev.scope))


def classify_token_error(status: int, body: str) -> str:
    """→ auth | transient | http（provider.md §10.3 / §2.1）。"""
    if status == 0 or status == 429 or status >= 500:
        return "transient"
    try:
        obj = json.loads(body)
        err = obj.get("error") if isinstance(obj, dict) else None
    except Exception:
        err = None
    if isinstance(err, str) and err in ("invalid_grant", "invalid_client", "unauthorized_client"):
        return "auth"
    if 200 <= status < 300:
        return "ok"
    return "http"


# ---------------------------------------------------------------- driver

def run_case(case_dir: Path) -> list[dict]:
    script = json.loads((case_dir / "script.json").read_text(encoding="utf-8"))
    out = []
    for e in script["entries"]:
        kind = e["type"]
        row: dict = {"kind": kind, "name": e["name"]}
        if kind == "authorize":
            row["challenge"] = code_challenge(e["verifier"])
            row["url"] = authorization_url(e["provider"], e["clientId"], e["redirectUri"],
                                           e["verifier"], e["state"])
        elif kind == "redirect":
            row["result"] = parse_redirect(e["url"], e["state"])
        elif kind == "form":
            row["exchange"] = exchange_form(e["clientId"], e["code"], e["verifier"], e["redirectUri"])
            row["refresh"] = refresh_form(e["clientId"], e["refreshToken"])
        elif kind == "token_response":
            prev = TokenState.parse(e.get("prev"))
            state = apply_token_response(prev, e["body"], e["nowMs"])
            row["serialized"] = state.serialize()
            row["state"] = state.to_json()
            row["needsRefresh"] = state.needs_refresh(e["nowMs"])
            row["usable"] = state.is_usable(e["nowMs"])
        elif kind == "expiry":
            state = TokenState.parse(e["state"])
            row["needsRefresh"] = state.needs_refresh(e["nowMs"])
            row["usable"] = state.is_usable(e["nowMs"])
        elif kind == "error":
            row["class"] = classify_token_error(e["status"], e["body"])
        else:
            raise ValueError(kind)
        out.append(row)
    return out


def build_scripts() -> dict[str, dict]:
    verifier = "muVerifier-0123456789abcdefghijklmnopqrstuvwxyz~._-"
    return {
        "oauth_authorize": {"entries": [
            {"type": "authorize", "name": "gdrive_mobile", "provider": "gdrive",
             "clientId": "123-abc.apps.googleusercontent.com",
             "redirectUri": "at.least.crate.ios:/oauth2redirect",
             "verifier": verifier, "state": "st-1"},
            {"type": "authorize", "name": "gdrive_loopback", "provider": "gdrive",
             "clientId": "123-abc.apps.googleusercontent.com",
             "redirectUri": "http://127.0.0.1:7777/callback",
             "verifier": verifier, "state": "st 2"},
            {"type": "authorize", "name": "dropbox_mobile", "provider": "dropbox",
             "clientId": "dbx-key", "redirectUri": "at.least.crate.android:/oauth2redirect",
             "verifier": verifier, "state": "st-3"},
            {"type": "authorize", "name": "unicode_state", "provider": "dropbox",
             "clientId": "dbx-key", "redirectUri": "at.least.crate.android:/oauth2redirect",
             "verifier": "short-verifier", "state": "狀態/+&=?"},
        ]},
        "oauth_redirect": {"entries": [
            {"type": "redirect", "name": "ok",
             "url": "at.least.crate.ios:/oauth2redirect?code=abc123&state=st-1", "state": "st-1"},
            {"type": "redirect", "name": "ok_percent_encoded",
             "url": "http://127.0.0.1:7777/callback?code=a%2Fb%2Bc&state=st%202", "state": "st 2"},
            {"type": "redirect", "name": "denied",
             "url": "at.least.crate.ios:/oauth2redirect?error=access_denied&state=st-1", "state": "st-1"},
            {"type": "redirect", "name": "state_mismatch",
             "url": "at.least.crate.ios:/oauth2redirect?code=abc123&state=other", "state": "st-1"},
            {"type": "redirect", "name": "denied_state_mismatch",
             "url": "at.least.crate.ios:/oauth2redirect?error=access_denied&state=x", "state": "st-1"},
            {"type": "redirect", "name": "no_query",
             "url": "at.least.crate.ios:/oauth2redirect", "state": "st-1"},
            {"type": "redirect", "name": "no_code",
             "url": "at.least.crate.ios:/oauth2redirect?state=st-1", "state": "st-1"},
            {"type": "redirect", "name": "with_fragment",
             "url": "at.least.crate.ios:/oauth2redirect?code=abc&state=st-1#frag", "state": "st-1"},
        ]},
        "oauth_forms": {"entries": [
            {"type": "form", "name": "gdrive", "clientId": "123-abc.apps.googleusercontent.com",
             "code": "4/0Ab_c-d", "verifier": verifier,
             "redirectUri": "at.least.crate.ios:/oauth2redirect", "refreshToken": "1//rt-token"},
            {"type": "form", "name": "dropbox", "clientId": "dbx-key", "code": "code+with/chars",
             "verifier": "short-verifier", "redirectUri": "http://127.0.0.1:7777/callback",
             "refreshToken": "rt&x=1"},
        ]},
        "oauth_tokens": {"entries": [
            {"type": "token_response", "name": "exchange_full", "nowMs": 1700000000000,
             "body": json.dumps({"access_token": "at-1", "refresh_token": "rt-1",
                                 "expires_in": 3599, "scope": "drive.readonly",
                                 "token_type": "Bearer"})},
            {"type": "token_response", "name": "refresh_keeps_refresh_token",
             "nowMs": 1700003600000,
             "prev": json.dumps({"accessToken": "at-1", "refreshToken": "rt-1",
                                 "expiresAtMs": 1700003599000, "scope": "drive.readonly"}),
             "body": json.dumps({"access_token": "at-2", "expires_in": 3599})},
            {"type": "token_response", "name": "expires_in_missing", "nowMs": 1700000000000,
             "body": json.dumps({"access_token": "at-3", "refresh_token": "rt-3"})},
            {"type": "token_response", "name": "expires_in_string", "nowMs": 1700000000000,
             "body": json.dumps({"access_token": "at-4", "expires_in": "600"})},
            {"type": "token_response", "name": "garbage_body", "nowMs": 1700000000000,
             "prev": json.dumps({"accessToken": "at-old", "refreshToken": "rt-old",
                                 "expiresAtMs": 1, "scope": "s"}),
             "body": "not json"},
        ]},
        "oauth_expiry": {"entries": [
            {"type": "expiry", "name": "fresh", "nowMs": 1700000000000,
             "state": json.dumps({"accessToken": "at", "refreshToken": "rt",
                                  "expiresAtMs": 1700003600000, "scope": ""})},
            {"type": "expiry", "name": "inside_skew", "nowMs": 1700003550000,
             "state": json.dumps({"accessToken": "at", "refreshToken": "rt",
                                  "expiresAtMs": 1700003600000, "scope": ""})},
            {"type": "expiry", "name": "exactly_skew", "nowMs": 1700003540000,
             "state": json.dumps({"accessToken": "at", "refreshToken": "rt",
                                  "expiresAtMs": 1700003600000, "scope": ""})},
            {"type": "expiry", "name": "expired", "nowMs": 1700009999000,
             "state": json.dumps({"accessToken": "at", "refreshToken": "rt",
                                  "expiresAtMs": 1700003600000, "scope": ""})},
            {"type": "expiry", "name": "empty_state", "nowMs": 1700000000000, "state": ""},
            {"type": "expiry", "name": "no_access_token", "nowMs": 1700000000000,
             "state": json.dumps({"accessToken": "", "refreshToken": "rt",
                                  "expiresAtMs": 1700003600000, "scope": ""})},
        ]},
        "oauth_errors": {"entries": [
            {"type": "error", "name": "invalid_grant", "status": 400,
             "body": json.dumps({"error": "invalid_grant"})},
            {"type": "error", "name": "invalid_client", "status": 401,
             "body": json.dumps({"error": "invalid_client"})},
            {"type": "error", "name": "unauthorized_client", "status": 400,
             "body": json.dumps({"error": "unauthorized_client"})},
            {"type": "error", "name": "rate_limited", "status": 429, "body": ""},
            {"type": "error", "name": "server_error", "status": 503, "body": ""},
            {"type": "error", "name": "transport_failure", "status": 0, "body": ""},
            {"type": "error", "name": "other_4xx", "status": 403,
             "body": json.dumps({"error": "insufficient_scope"})},
            {"type": "error", "name": "ok", "status": 200,
             "body": json.dumps({"access_token": "at"})},
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

    r = rows("oauth_authorize")
    url = r["gdrive_mobile"]["url"]
    assert url.startswith("https://accounts.google.com/o/oauth2/v2/auth?client_id=")
    assert "code_challenge_method=S256" in url and url.endswith("&access_type=offline&prompt=consent")
    assert "%3A%2F%2F" in url and "redirect_uri=at.least.crate.ios%3A%2Foauth2redirect" in url
    assert r["gdrive_loopback"]["url"].count("state=st%202") == 1, "空白 → %20"
    assert r["dropbox_mobile"]["url"].endswith("&token_access_type=offline")
    assert r["gdrive_mobile"]["challenge"] == r["gdrive_loopback"]["challenge"], "同 verifier 同 challenge"
    assert "=" not in r["gdrive_mobile"]["challenge"], "base64url 去 padding"

    r = rows("oauth_redirect")
    assert r["ok"]["result"] == {"status": "ok", "code": "abc123"}
    assert r["ok_percent_encoded"]["result"] == {"status": "ok", "code": "a/b+c"}
    assert r["denied"]["result"] == {"status": "denied", "error": "access_denied"}
    assert r["state_mismatch"]["result"]["status"] == "state_mismatch"
    assert r["denied_state_mismatch"]["result"]["status"] == "state_mismatch"
    assert r["no_query"]["result"]["status"] == "invalid"
    assert r["no_code"]["result"]["status"] == "invalid"
    assert r["with_fragment"]["result"] == {"status": "ok", "code": "abc"}

    r = rows("oauth_forms")
    assert r["gdrive"]["exchange"].startswith("client_id=123-abc.apps.googleusercontent.com&code=4%2F0Ab_c-d&")
    assert r["gdrive"]["refresh"] == \
        "client_id=123-abc.apps.googleusercontent.com&grant_type=refresh_token&refresh_token=1%2F%2Frt-token"
    assert "code=code%2Bwith%2Fchars" in r["dropbox"]["exchange"]

    r = rows("oauth_tokens")
    assert r["exchange_full"]["state"] == {
        "accessToken": "at-1", "expiresAtMs": 1700003599000,
        "refreshToken": "rt-1", "scope": "drive.readonly"}
    assert r["refresh_keeps_refresh_token"]["state"]["refreshToken"] == "rt-1", "回應無 refresh → 沿用"
    assert r["expires_in_missing"]["state"]["expiresAtMs"] == 1700000000000
    assert r["expires_in_missing"]["needsRefresh"] is True
    assert r["expires_in_string"]["state"]["expiresAtMs"] == 1700000600000
    assert r["garbage_body"]["state"]["accessToken"] == "at-old", "壞 body → 保留舊值"

    r = rows("oauth_expiry")
    assert r["fresh"]["usable"] is True and r["fresh"]["needsRefresh"] is False
    assert r["inside_skew"]["needsRefresh"] is True, "提前一分鐘換"
    assert r["exactly_skew"]["needsRefresh"] is True, "邊界含等號"
    assert r["expired"]["usable"] is False
    assert r["empty_state"]["usable"] is False
    assert r["no_access_token"]["usable"] is False

    r = rows("oauth_errors")
    assert [r[k]["class"] for k in ("invalid_grant", "invalid_client", "unauthorized_client")] == \
        ["auth", "auth", "auth"]
    assert [r[k]["class"] for k in ("rate_limited", "server_error", "transport_failure")] == \
        ["transient", "transient", "transient"]
    assert r["other_4xx"]["class"] == "http" and r["ok"]["class"] == "ok"
    print(f"OK: {len(scripts)} oauth cases generated, all sanity asserts passed")


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
        print(f"DRIFT: {len(bad)} oauth case(s) differ: {', '.join(bad)}")
        return 1
    print("OK: all oauth cases byte-identical to expected.json")
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
