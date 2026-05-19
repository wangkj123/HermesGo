"""Send 'hello' via Hermes CLI, Dashboard, WebUI, and Desktop WS; report replies."""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any


def _app_root() -> str:
    override = os.environ.get("HERMESGO_TEST_APP_ROOT", "").strip()
    if override:
        return override
    here = os.path.dirname(os.path.abspath(__file__))
    return os.path.abspath(os.path.join(here, ".."))


def _portable_env(app_root: str) -> dict[str, str]:
    home = os.path.join(app_root, "home")
    agent = os.path.join(app_root, "runtime", "hermes-agent")
    py = os.path.join(app_root, "runtime", "python311")
    parts = [
        os.path.join(app_root, "runtime", "bin"),
        py,
        os.path.join(py, "Scripts"),
        app_root,
    ]
    sys32 = os.path.join(os.environ.get("WINDIR", r"C:\Windows"), "System32")
    if os.path.isdir(sys32):
        parts.append(sys32)
    env = os.environ.copy()
    env["HERMES_HOME"] = home
    env["PATH"] = os.pathsep.join(parts)
    env.pop("PYTHONHOME", None)
    env.pop("PYTHONPATH", None)
  # load .env into env for subprocesses
    env_path = os.path.join(home, ".env")
    if os.path.isfile(env_path):
        for line in open(env_path, encoding="utf-8", errors="replace"):
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            k, v = k.strip(), v.strip().strip('"').strip("'")
            if k and v:
                env[k] = v
    return env


def _http_json(
    method: str,
    url: str,
    payload: dict | None = None,
    token: str | None = None,
    timeout: float = 120.0,
) -> tuple[int, Any]:
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    data = None if payload is None else json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = resp.read().decode("utf-8", errors="replace")
            return resp.status, json.loads(body) if body else {}
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        try:
            parsed = json.loads(body)
        except Exception:
            parsed = {"raw": body[:500]}
        return exc.code, parsed


def _dashboard_token() -> str:
    req = urllib.request.Request("http://127.0.0.1:9119/env?quick=1")
    with urllib.request.urlopen(req, timeout=12) as resp:
        text = resp.read().decode("utf-8", errors="replace")
    m = re.search(r'__HERMES_SESSION_TOKEN__\s*=\s*["\']([^"\']+)', text)
    if not m:
        raise RuntimeError("dashboard session token not found")
    return m.group(1)


def _snippet(text: str, limit: int = 200) -> str:
    t = re.sub(r"\s+", " ", (text or "").strip())
    if len(t) <= limit:
        return t
    return t[: limit - 3] + "..."


def test_cli(app_root: str, env: dict[str, str]) -> tuple[bool, str]:
    py = os.path.join(app_root, "runtime", "python311", "python.exe")
    agent = os.path.join(app_root, "runtime", "hermes-agent")
    cmd = [py, "-m", "hermes_cli.main", "chat", "-q", "hello", "-Q"]
    started = time.time()
    proc = subprocess.run(
        cmd,
        cwd=agent,
        env=env,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=180,
    )
    out = (proc.stdout or "") + (proc.stderr or "")
    if proc.returncode != 0:
        return False, f"exit {proc.returncode}: {_snippet(out, 300)}"
    if not out.strip():
        return False, "no output"
    low = out.lower()
    if "insufficient balance" in low or "http 402" in low:
        return False, f"provider billing: {_snippet(out, 300)}"
    return True, _snippet(out, 400)


def test_dashboard(token: str) -> tuple[bool, str]:
    status, data = _http_json(
        "POST",
        "http://127.0.0.1:9119/api/chat",
        {"message": "hello", "timeout_sec": 120},
        token=token,
        timeout=130.0,
    )
    if status != 200:
        return False, f"HTTP {status}: {data}"
    if not isinstance(data, dict):
        return False, str(data)
    if not data.get("ok"):
        reply = str(data.get("response") or data)
        return False, _snippet(reply or str(data), 300)
    reply = str(data.get("response") or "")
    if not reply.strip():
        return False, f"empty response: {data}"
    low = reply.lower()
    if "insufficient balance" in low or "http 402" in low:
        return False, f"provider billing: {_snippet(reply, 300)}"
    return True, _snippet(reply, 400)


def test_webui() -> tuple[bool, str]:
    status, sess = _http_json("POST", "http://127.0.0.1:8787/api/session/new", {})
    if status != 200:
        return False, f"session/new HTTP {status}: {sess}"
    sid = (sess or {}).get("session", {}).get("session_id") or (sess or {}).get("session_id")
    if not sid:
        return False, f"no session_id: {sess}"
    status, start = _http_json(
        "POST",
        "http://127.0.0.1:8787/api/chat/start",
        {"session_id": sid, "message": "hello"},
        timeout=30.0,
    )
    if status != 200:
        return False, f"chat/start HTTP {status}: {start}"
    stream_id = (start or {}).get("stream_id")
    if not stream_id:
        return False, f"no stream_id: {start}"

    url = f"http://127.0.0.1:8787/api/chat/stream?stream_id={urllib.parse.quote(stream_id)}"
    req = urllib.request.Request(url)
    deadline = time.time() + 120
    chunks: list[str] = []
    try:
        with urllib.request.urlopen(req, timeout=125) as resp:
            while time.time() < deadline:
                line = resp.readline().decode("utf-8", errors="replace")
                if not line:
                    break
                if line.startswith("data:"):
                    payload = line[5:].strip()
                    if payload and payload != "[DONE]":
                        try:
                            evt = json.loads(payload)
                        except Exception:
                            continue
                        for key in ("text", "content", "delta", "message"):
                            val = evt.get(key) if isinstance(evt, dict) else None
                            if isinstance(val, str) and val.strip():
                                chunks.append(val)
                        if isinstance(evt, dict) and evt.get("type") in (
                            "assistant",
                            "assistant_message",
                            "done",
                            "complete",
                        ):
                            msg = evt.get("content") or evt.get("text") or ""
                            if isinstance(msg, str) and msg.strip():
                                chunks.append(msg)
    except Exception as exc:
        return False, f"stream error: {exc}"

    reply = "".join(chunks).strip()
    if reply:
        low = reply.lower()
        if "insufficient balance" in low or "http 402" in low or "api call failed" in low:
            return False, f"provider error: {_snippet(reply, 300)}"
        return True, _snippet(reply, 400)
    # fallback: session messages
    status, detail = _http_json(
        "GET",
        f"http://127.0.0.1:8787/api/session?session_id={urllib.parse.quote(sid)}",
        timeout=15.0,
    )
    if status == 200 and isinstance(detail, dict):
        messages = detail.get("session", {}).get("messages") or []
        for msg in reversed(messages):
            if msg.get("role") == "assistant":
                content = msg.get("content") or ""
                if isinstance(content, str) and content.strip():
                    return True, _snippet(content, 400)
    return False, "no assistant text in stream or session"


def _desktop_event_text(params: dict) -> tuple[str, str]:
    """Return (event_type, text) from a tui_gateway WS event frame."""
    if not isinstance(params, dict):
        return "", ""
    etype = str(params.get("type") or "")
    payload = params.get("payload")
    if not isinstance(payload, dict):
        payload = {}
    text = str(
        payload.get("text")
        or payload.get("content")
        or payload.get("message")
        or params.get("message")
        or ""
    )
    if etype == "error" and not text:
        text = str(payload.get("message") or "")
    return etype, text


def _desktop_collect_event(msg: dict, replies: list[str], errors: list[str]) -> bool:
    """Collect assistant text; return True when the turn is finished."""
    if msg.get("method") != "event":
        return False
    etype, text = _desktop_event_text(msg.get("params") or {})
    if etype == "error" and text:
        errors.append(text)
    elif etype in (
        "message.delta",
        "message.complete",
        "assistant",
        "message",
        "assistant.delta",
        "stream.delta",
    ) and text:
        replies.append(text)
    return etype == "message.complete" and bool(text or replies)


def test_desktop_ws(token: str) -> tuple[bool, str]:
    try:
        import asyncio
        import websockets
    except ImportError:
        return False, "websockets package not available"

    replies: list[str] = []
    errors: list[str] = []

    async def run() -> None:
        uri = f"ws://127.0.0.1:9119/api/ws?token={token}"
        async with websockets.connect(uri, open_timeout=15) as ws:
            rid = 1

            async def call(method: str, params: dict | None = None) -> dict:
                nonlocal rid
                req_id = rid
                rid += 1
                await ws.send(
                    json.dumps(
                        {
                            "jsonrpc": "2.0",
                            "id": req_id,
                            "method": method,
                            "params": params or {},
                        }
                    )
                )
                while True:
                    raw = await asyncio.wait_for(ws.recv(), timeout=120)
                    msg = json.loads(raw)
                    if _desktop_collect_event(msg, replies, errors):
                        return msg.get("result") or {}
                    if msg.get("id") == req_id:
                        if "error" in msg:
                            err = msg["error"]
                            errors.append(
                                err.get("message", str(err))
                                if isinstance(err, dict)
                                else str(err)
                            )
                        return msg.get("result") or {}

            # gateway.ready
            try:
                raw0 = await asyncio.wait_for(ws.recv(), timeout=10)
                _desktop_collect_event(json.loads(raw0), replies, errors)
            except Exception:
                pass

            created = await call("session.create", {})
            sid = created.get("session_id") or created.get("id")
            if not sid:
                errors.append(f"session.create: {created}")
                return
            await call("prompt.submit", {"session_id": sid, "text": "hello"})
            if replies:
                return
            end = time.time() + 120
            idle_rounds = 0
            while time.time() < end:
                try:
                    raw = await asyncio.wait_for(ws.recv(), timeout=8)
                except asyncio.TimeoutError:
                    idle_rounds += 1
                    if replies and idle_rounds >= 3:
                        break
                    continue
                except Exception as exc:
                    if replies:
                        break
                    errors.append(str(exc))
                    break
                idle_rounds = 0
                try:
                    msg = json.loads(raw)
                except Exception:
                    continue
                if _desktop_collect_event(msg, replies, errors):
                    break

    asyncio.run(run())
    if errors and not replies:
        return False, _snippet("; ".join(errors), 300)
    reply = "".join(replies).strip()
    if reply:
        low = reply.lower()
        if "insufficient balance" in low or "http 402" in low or "api call failed" in low:
            return False, f"provider error: {_snippet(reply, 300)}"
        return True, _snippet(reply, 400)
    if errors:
        return False, _snippet("; ".join(errors), 300)
    return False, "no assistant event on Desktop WS"


def _safe_print(text: str) -> None:
    try:
        print(text)
    except UnicodeEncodeError:
        print(text.encode(sys.stdout.encoding or "utf-8", errors="replace").decode(
            sys.stdout.encoding or "utf-8", errors="replace"
        ))


def main() -> int:
    app_root = _app_root()
    if not os.path.isfile(os.path.join(app_root, "runtime", "python311", "python.exe")):
        app_root = os.path.join(os.path.dirname(app_root), "app")

    env = _portable_env(app_root)
    failures = 0

    for name, port in (("dashboard", 9119), ("webui", 8787)):
        try:
            urllib.request.urlopen(f"http://127.0.0.1:{port}/", timeout=3)
        except Exception:
            _safe_print(f"FAIL {name}: not listening on {port}")
            failures += 1

    _safe_print("=== Hermes hello smoke (CLI + Dashboard + WebUI + Desktop WS) ===")
    _safe_print(f"app_root: {app_root}")

    try:
        token = _dashboard_token()
    except Exception as exc:
        _safe_print(f"FAIL token: {exc}")
        return 1

    tests = [
        ("hermes-cli", lambda: test_cli(app_root, env)),
        ("dashboard-9119", lambda: test_dashboard(token)),
        ("webui-8787", lambda: test_webui()),
        ("desktop-ws-9119", lambda: test_desktop_ws(token)),
    ]

    for label, fn in tests:
        _safe_print(f"\n--- {label} ---")
        try:
            ok, detail = fn()
        except subprocess.TimeoutExpired:
            ok, detail = False, "timeout"
        except Exception as exc:
            ok, detail = False, str(exc)
        if ok:
            _safe_print(f"OK {label}: {detail}")
        else:
            _safe_print(f"FAIL {label}: {detail}")
            failures += 1

    if failures:
        _safe_print(f"\nFAILED ({failures} checks)")
        return 1
    _safe_print("\nALL hello checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
