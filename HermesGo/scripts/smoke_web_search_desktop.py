"""Smoke: Desktop/gateway exposes web_search and uses it for a factual web query."""
from __future__ import annotations

import asyncio
import json
import os
import re
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

QUERY = (
    "中国现在有完整回收的轨道火箭吗？除 SpaceX 外还有哪些国家或公司实现过火箭回收？"
    "请先用 web_search 查最新信息再回答，不要用 curl 或 python 脚本搜网页。"
)


def _app_root() -> str:
    override = os.environ.get("HERMESGO_TEST_APP_ROOT", "").strip()
    if override:
        return override
    here = os.path.dirname(os.path.abspath(__file__))
    pkg = os.path.abspath(os.path.join(here, "..", "..", "HermesGo-slim-test-v014", "HermesGo"))
    app = os.path.join(pkg, "app")
    if os.path.isfile(os.path.join(app, "runtime", "python311", "python.exe")):
        return app
    return os.path.abspath(os.path.join(here, ".."))


def _portable_env(app: str) -> dict[str, str]:
    home = os.path.join(app, "home")
    py = os.path.join(app, "runtime", "python311")
    parts = [
        os.path.join(app, "runtime", "bin"),
        py,
        os.path.join(py, "Scripts"),
        app,
    ]
    env = os.environ.copy()
    env["HERMES_HOME"] = home
    env["HERMES_PORTABLE_APP_ROOT"] = os.path.normpath(app)
    env["PATH"] = os.pathsep.join(parts)
    env.pop("PYTHONHOME", None)
    env.pop("PYTHONPATH", None)
    dotenv = os.path.join(home, ".env")
    if os.path.isfile(dotenv):
        for line in Path(dotenv).read_text(encoding="utf-8", errors="replace").splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            k = k.strip().lstrip("\ufeff")
            v = v.strip().strip('"').strip("'")
            if k and v:
                env[k] = v
    return env


def _http_ok(url: str) -> bool:
    try:
        with urllib.request.urlopen(url, timeout=6) as resp:
            return 200 <= resp.status < 400
    except Exception:
        return False


def _dashboard_token() -> str:
    with urllib.request.urlopen("http://127.0.0.1:9119/env?quick=1", timeout=12) as resp:
        text = resp.read().decode("utf-8", errors="replace")
    m = re.search(r'__HERMES_SESSION_TOKEN__\s*=\s*["\']([^"\']+)', text)
    if not m:
        raise RuntimeError("dashboard session token not found")
    return m.group(1)


def _start_services(package: str) -> None:
    bat = os.path.join(package, "HermesGo.bat")
    if not os.path.isfile(bat):
        bat = os.path.join(os.path.dirname(package), "HermesGo.bat")
    ps = os.path.join(os.environ.get("SystemRoot", r"C:\Windows"), "System32", "WindowsPowerShell", "v1.0", "powershell.exe")
    subprocess.run(
        [ps, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", os.path.join(package, "app", "scripts", "Start-HermesGo.ps1")],
        cwd=package,
        env=_portable_env(os.path.join(package, "app")),
        timeout=180,
        check=False,
    )


def _agent_tools_check(app: str) -> tuple[bool, str]:
    py = os.path.join(app, "runtime", "python311", "python.exe")
    agent = os.path.join(app, "runtime", "hermes-agent")
    env = _portable_env(app)
    code = f"""
import sys
sys.path.insert(0, r'{agent}')
from hermes_cli.config import load_config
from hermes_cli.tools_config import _get_platform_tools
from model_tools import get_tool_definitions
from tools.web_tools import check_web_api_key
cfg = load_config()
enabled = sorted(_get_platform_tools(cfg, 'cli', include_default_mcp_servers=True))
tools = get_tool_definitions(enabled_toolsets=enabled, quiet_mode=True)
names = {{t['function']['name'] for t in tools}}
ok = check_web_api_key() and 'web_search' in names
print('OK' if ok else 'FAIL', 'web' in enabled, check_web_api_key(), 'web_search' in names, len(names))
"""
    r = subprocess.run([py, "-c", code], capture_output=True, text=True, env=env, timeout=60)
    out = (r.stdout or "") + (r.stderr or "")
    return r.returncode == 0 and out.strip().startswith("OK"), out.strip()


async def _desktop_turn(token: str) -> tuple[bool, str, list[str]]:
    import websockets

    tool_calls: list[str] = []
    replies: list[str] = []
    errors: list[str] = []

    uri = f"ws://127.0.0.1:9119/api/ws?token={token}"
    async with websockets.connect(uri, open_timeout=20) as ws:
        rid = 1

        async def call(method: str, params: dict | None = None) -> dict:
            nonlocal rid
            req_id = rid
            rid += 1
            await ws.send(
                json.dumps(
                    {"jsonrpc": "2.0", "id": req_id, "method": method, "params": params or {}}
                )
            )
            while True:
                raw = await asyncio.wait_for(ws.recv(), timeout=180)
                msg = json.loads(raw)
                if msg.get("method") == "event":
                    params_ev = msg.get("params") or {}
                    etype = str(params_ev.get("type") or "")
                    payload = params_ev.get("payload") if isinstance(params_ev.get("payload"), dict) else {}
                    if etype in ("tool.start", "tool.started", "tool.end", "tool.completed"):
                        name = str(payload.get("name") or payload.get("tool") or "")
                        if name:
                            tool_calls.append(name)
                    elif etype == "tool.end":
                        name = str(payload.get("name") or payload.get("tool") or "")
                        if name and name not in tool_calls:
                            tool_calls.append(name)
                    text = str(
                        payload.get("text")
                        or payload.get("content")
                        or payload.get("message")
                        or ""
                    )
                    if etype in ("message.delta", "message.complete", "assistant") and text:
                        replies.append(text)
                    if etype == "error":
                        errors.append(str(payload.get("message") or text or "error"))
                    if etype == "message.complete":
                        return msg.get("result") or {}
                if msg.get("id") == req_id:
                    if "error" in msg:
                        err = msg["error"]
                        errors.append(err.get("message", str(err)) if isinstance(err, dict) else str(err))
                    return msg.get("result") or {}

        try:
            raw0 = await asyncio.wait_for(ws.recv(), timeout=8)
            msg0 = json.loads(raw0)
            if msg0.get("method") == "event":
                pass
        except Exception:
            pass

        tools_res = await call("tools.show", {})
        flat: list[str] = []
        sections = tools_res.get("sections") or []
        if isinstance(sections, dict):
            for items in sections.values():
                if isinstance(items, list):
                    flat.extend(i.get("name") for i in items if isinstance(i, dict))
        elif isinstance(sections, list):
            for block in sections:
                if isinstance(block, dict):
                    for item in block.get("tools") or []:
                        if isinstance(item, dict) and item.get("name"):
                            flat.append(str(item["name"]))
        if "web_search" not in flat:
            return False, f"tools.show missing web_search; have={sorted(flat)[:25]}", tool_calls

        created = await call("session.create", {})
        sid = created.get("session_id") or created.get("id")
        if not sid:
            return False, f"session.create failed: {created}", tool_calls

        await call("prompt.submit", {"session_id": sid, "text": QUERY})
        end = time.time() + 150
        while time.time() < end:
            try:
                raw = await asyncio.wait_for(ws.recv(), timeout=12)
            except asyncio.TimeoutError:
                if replies:
                    break
                continue
            msg = json.loads(raw)
            if msg.get("method") == "event":
                params_ev = msg.get("params") or {}
                etype = str(params_ev.get("type") or "")
                payload = params_ev.get("payload") if isinstance(params_ev.get("payload"), dict) else {}
                if etype in ("tool.start", "tool.end"):
                    name = str(payload.get("name") or payload.get("tool") or "")
                    if name:
                        tool_calls.append(name)
                text = str(payload.get("text") or payload.get("content") or "")
                if etype in ("message.delta", "message.complete") and text:
                    replies.append(text)
                if etype == "message.complete":
                    break

    reply = "".join(replies)
    bad = [t for t in tool_calls if t == "terminal" and "python3" in reply.lower()]
    used_web = "web_search" in tool_calls
    used_bad = any(
        x in " ".join(tool_calls).lower() or "urllib" in reply.lower() or "python3 -c" in reply.lower()
        for x in ("terminal",)
    ) and not used_web

    if used_web:
        return True, f"web_search called; tools={tool_calls}; reply={reply[:200]}", tool_calls
    if errors and not reply:
        return False, "; ".join(errors), tool_calls
    return False, f"no web_search in tool_calls={tool_calls}; reply={reply[:300]}", tool_calls


def main() -> int:
    app = _app_root()
    package = os.path.dirname(app) if os.path.basename(app).lower() == "app" else app
    env = _portable_env(app)
    failures = 0

    ok_tools, detail = _agent_tools_check(app)
    print(f"{'OK' if ok_tools else 'FAIL'} agent tool registry: {detail}")
    if not ok_tools:
        failures += 1

    def _kill_listeners() -> None:
        for port in (9119, 8787, 8642):
            try:
                ps = subprocess.run(
                    [
                        "powershell",
                        "-NoProfile",
                        "-Command",
                        (
                            f"Get-NetTCPConnection -LocalPort {port} -State Listen -ErrorAction SilentlyContinue | "
                            "Select-Object -ExpandProperty OwningProcess -Unique | "
                            "ForEach-Object { if ($_ -and $_ -ne $PID) { Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue } }"
                        ),
                    ],
                    capture_output=True,
                    timeout=15,
                )
            except Exception:
                pass
        pid_file = os.path.join(app, "home", "gateway.pid")
        if os.path.isfile(pid_file):
            try:
                raw = Path(pid_file).read_text(encoding="utf-8", errors="replace").strip()
                if raw.isdigit():
                    subprocess.run(["taskkill", "/PID", raw, "/F"], capture_output=True, timeout=10)
            except Exception:
                pass

    if not _http_ok("http://127.0.0.1:9119/"):
        print("starting HermesGo services...")
        _start_services(package)
        for _ in range(45):
            if _http_ok("http://127.0.0.1:9119/"):
                break
            time.sleep(2)
    if not _http_ok("http://127.0.0.1:9119/"):
        print("FAIL dashboard not up on :9119")
        return 1

    try:
        token = _dashboard_token()
    except Exception as exc:
        print(f"FAIL token: {exc}")
        return 1

    # restart gateway to pick up code
    ps = os.path.join(os.environ.get("SystemRoot", r"C:\Windows"), "System32", "WindowsPowerShell", "v1.0", "powershell.exe")
    restart = os.path.join(os.path.dirname(__file__), "Restart-HermesGoServices.ps1")
    if os.path.isfile(restart):
        subprocess.run(
            [ps, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", restart, "-AppRoot", app],
            env=env,
            timeout=30,
        )
        _kill_listeners()
        time.sleep(2)
        _start_services(package)
        for _ in range(30):
            if _http_ok("http://127.0.0.1:9119/"):
                break
            time.sleep(2)
        token = _dashboard_token()

    try:
        ok, msg, tools = asyncio.run(_desktop_turn(token))
    except Exception as exc:
        print(f"FAIL desktop ws: {exc}")
        failures += 1
    else:
        print(f"{'OK' if ok else 'FAIL'} desktop turn: {msg}")
        print(f"  tool_calls: {tools}")
        if not ok:
            failures += 1

    log_dir = os.path.join(app, "home", "logs")
    agent_log = os.path.join(log_dir, "agent.log")
    if os.path.isfile(agent_log):
        tail = Path(agent_log).read_text(encoding="utf-8", errors="replace").splitlines()[-15:]
        print("--- agent.log (tail) ---")
        for line in tail:
            print(line)

    sessions_dir = os.path.join(app, "home", "sessions")
    if os.path.isdir(sessions_dir):
        latest = max(Path(sessions_dir).glob("session_*.json"), key=lambda p: p.stat().st_mtime, default=None)
        if latest:
            data = json.loads(latest.read_text(encoding="utf-8", errors="replace"))
            names = [t.get("function", {}).get("name") for m in data.get("messages", []) for t in (m.get("tool_calls") or []) if isinstance(t, dict)]
            names += [
                m.get("name")
                for m in data.get("messages", [])
                if m.get("role") == "tool"
            ]
            if "web_search" in str(names) or any(n == "web_search" for n in names if n):
                print(f"OK session {latest.name}: web_search present in transcript")
            else:
                bad_cmds = []
                for m in data.get("messages", []):
                    if m.get("role") == "assistant" and m.get("tool_calls"):
                        for tc in m["tool_calls"]:
                            fn = tc.get("function") or {}
                            if fn.get("name") == "terminal" and "python3" in str(fn.get("arguments", "")):
                                bad_cmds.append("terminal+python3")
                            if fn.get("name") == "web_search":
                                bad_cmds.append("web_search")
                print(f"session {latest.name} tool usage: {bad_cmds or 'none detected'}")
                if "web_search" not in bad_cmds and bad_cmds:
                    failures += 1

    if failures:
        print(f"FAILED ({failures} checks)")
        return 1
    print("ALL WEB_SEARCH SMOKE CHECKS PASSED")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
