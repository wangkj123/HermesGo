"""Smoke-test Kanban across WebUI (8787), Dashboard (9119), and Desktop (9119 remote).

Desktop uses the same Dashboard backend; this script verifies the shared
kanban.db is readable/writable from both HTTP surfaces after gateway startup.
"""
from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.request
from typing import Any


def _app_root() -> str:
    override = os.environ.get("HERMESGO_TEST_APP_ROOT", "").strip()
    if override:
        return override
    here = os.path.dirname(os.path.abspath(__file__))
    return os.path.abspath(os.path.join(here, ".."))


def _http_raw(
    method: str,
    url: str,
    *,
    token: str | None = None,
    body: dict | None = None,
    timeout: float = 12.0,
) -> tuple[int, bytes]:
    headers: dict[str, str] = {}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    data = None
    if body is not None:
        headers["Content-Type"] = "application/json"
        data = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read()


def _http(
    method: str,
    url: str,
    *,
    token: str | None = None,
    body: dict | None = None,
    timeout: float = 12.0,
) -> tuple[int, Any]:
    status, raw = _http_raw(method, url, token=token, body=body, timeout=timeout)
    if not raw:
        return status, None
    try:
        return status, json.loads(raw.decode("utf-8"))
    except json.JSONDecodeError:
        return status, {"_raw": raw.decode("utf-8", errors="replace")[:500]}


def _dashboard_token(app_root: str) -> str | None:
    try:
        status, raw = _http_raw("GET", "http://127.0.0.1:9119/env?quick=1", timeout=8.0)
    except Exception:
        return None
    if status != 200:
        return None
    text = raw.decode("utf-8", errors="replace")
    marker = '__HERMES_SESSION_TOKEN__="'
    start = text.find(marker)
    if start < 0:
        return None
    start += len(marker)
    end = text.find('"', start)
    if end < 0:
        return None
    return text[start:end]


def _check(name: str, ok: bool, detail: str = "") -> bool:
    if ok:
        print(f"OK  {name}" + (f": {detail}" if detail else ""))
        return True
    print(f"FAIL {name}" + (f": {detail}" if detail else ""))
    return False


def _test_webui(failures: list[str]) -> None:
    print("\n=== WebUI 8787 (/api/kanban/*) ===")
    endpoints = (
        ("GET", "/api/kanban/boards", None),
        ("GET", "/api/kanban/config", None),
        ("GET", "/api/kanban/board", None),
        ("GET", "/api/kanban/assignees", None),
        ("GET", "/api/kanban/stats", None),
    )
    base = "http://127.0.0.1:8787"
    for method, path, body in endpoints:
        status, data = _http(method, base + path, body=body)
        if not _check(f"webui {method} {path}", status == 200, f"HTTP {status}"):
            failures.append(f"webui {path}")
            if isinstance(data, dict):
                print(f"      {data.get('error', data)}")

    status, created = _http(
        "POST",
        base + "/api/kanban/tasks",
        body={
            "title": "smoke-all-ui webui task",
            "assignee": "smoke",
            "tenant": "hermesgo",
            "priority": 1,
        },
    )
    task_id = None
    if _check("webui POST /api/kanban/tasks", status == 200, f"HTTP {status}"):
        task_id = (created or {}).get("task", {}).get("id")
        print(f"      task_id={task_id}")
    else:
        failures.append("webui create task")
        if isinstance(created, dict):
            print(f"      {created.get('error', created)}")

    if task_id:
        status, detail = _http("GET", f"{base}/api/kanban/tasks/{task_id}")
        _check(f"webui GET /api/kanban/tasks/{task_id}", status == 200, f"HTTP {status}") or failures.append(
            "webui task detail"
        )

    status, board = _http("GET", base + "/api/kanban/board")
    if status == 200 and task_id:
        tasks = [
            t
            for col in (board or {}).get("columns") or []
            for t in col.get("tasks") or []
        ]
        found = any(t.get("id") == task_id for t in tasks)
        _check("webui board lists created task", found, f"tasks on board={len(tasks)}") or failures.append(
            "webui board has task"
        )


def _test_dashboard(failures: list[str], token: str) -> None:
    print("\n=== Dashboard 9119 (/api/plugins/kanban/*) ===")
    base = "http://127.0.0.1:9119"
    status, plugins = _http("GET", base + "/api/dashboard/plugins", token=token)
    names = [p.get("name") for p in plugins if isinstance(p, dict)] if status == 200 else []
    _check("dashboard plugins includes kanban", status == 200 and "kanban" in names, str(names)) or failures.append(
        "dashboard plugin registry"
    )

    endpoints = (
        ("GET", "/api/plugins/kanban/boards", None),
        ("GET", "/api/plugins/kanban/config", None),
        ("GET", "/api/plugins/kanban/board", None),
        ("GET", "/api/plugins/kanban/stats", None),
        ("GET", "/api/plugins/kanban/assignees", None),
    )
    for method, path, body in endpoints:
        status, data = _http(method, base + path, token=token, body=body)
        if not _check(f"dashboard {method} {path}", status == 200, f"HTTP {status}"):
            failures.append(f"dashboard {path}")
            if isinstance(data, dict):
                detail = data.get("detail") or data.get("error") or data
                print(f"      {detail}")

    try:
        status, created = _http(
            "POST",
            base + "/api/plugins/kanban/tasks",
            token=token,
            body={
                "title": "smoke-all-ui dashboard task",
                "assignee": "smoke",
                "tenant": "hermesgo",
                "priority": 1,
            },
        )
    except urllib.error.HTTPError as exc:
        status, created = exc.code, {"detail": exc.read().decode("utf-8", errors="replace")[:300]}
    task_id = None
    if _check("dashboard POST /api/plugins/kanban/tasks", status == 200, f"HTTP {status}"):
        task = (created or {}).get("task") or created
        if isinstance(task, dict):
            task_id = task.get("id")
        print(f"      task_id={task_id}")
    else:
        failures.append("dashboard create task")
        if isinstance(created, dict):
            print(f"      {created.get('detail') or created.get('error') or created}")

    if task_id:
        status, _ = _http("GET", f"{base}/api/plugins/kanban/tasks/{task_id}", token=token)
        _check(f"dashboard GET task/{task_id}", status == 200, f"HTTP {status}") or failures.append(
            "dashboard task detail"
        )

    status, board = _http("GET", base + "/api/plugins/kanban/board", token=token)
    if status == 200 and task_id:
        cols = (board or {}).get("columns")
        if isinstance(cols, dict):
            tasks = [t for tasks in cols.values() for t in tasks]
        elif isinstance(cols, list):
            tasks = [t for col in cols for t in (col.get("tasks") or [])]
        else:
            tasks = []
        found = any(t.get("id") == task_id for t in tasks)
        _check("dashboard board lists created task", found, f"tasks on board={len(tasks)}") or failures.append(
            "dashboard board has task"
        )


def _test_desktop(failures: list[str], token: str) -> None:
    print("\n=== Desktop (remote Dashboard 9119) ===")
    # Desktop does not host its own kanban API; it uses Dashboard session.
    status, _ = _http("GET", "http://127.0.0.1:9119/", token=token)
    _check("dashboard root for desktop remote", status == 200, f"HTTP {status}") or failures.append(
        "desktop remote dashboard"
    )

    # Plugin static assets (Kanban tab JS/CSS)
    for path in (
        "/dashboard-plugins/kanban/dist/index.js",
        "/dashboard-plugins/kanban/dist/style.css",
    ):
        req = urllib.request.Request(
            f"http://127.0.0.1:9119{path}",
            method="GET",
            headers={"Authorization": f"Bearer {token}"},
        )
        try:
            with urllib.request.urlopen(req, timeout=8.0) as resp:
                ok = resp.status == 200 and len(resp.read()) > 100
        except Exception as exc:
            ok = False
            print(f"      {exc}")
        _check(f"desktop asset {path}", ok) or failures.append(f"desktop asset {path}")

    # Desktop process (optional)
    try:
        import subprocess

        out = subprocess.check_output(
            ["powershell", "-NoProfile", "-Command",
             "(Get-Process -Name Hermes -ErrorAction SilentlyContinue | Measure-Object).Count"],
            text=True,
            timeout=8,
        ).strip()
        count = int(out or "0")
        _check("Hermes Desktop process running", count >= 1, f"count={count}")
    except Exception as exc:
        print(f"WARN desktop process check skipped: {exc}")


def _test_path_consistency(app_root: str, failures: list[str], token: str | None) -> None:
    print("\n=== Path consistency (HERMES_HOME vs UI display) ===")
    expected_home = os.path.normpath(os.path.join(app_root, "home"))
    os.environ["HERMES_HOME"] = expected_home
    agent = os.path.join(app_root, "runtime", "hermes-agent")
    if agent not in sys.path:
        sys.path.insert(0, agent)
    try:
        from hermes_constants import display_hermes_home, get_hermes_home, get_portable_app_root

        actual = os.path.normpath(str(get_hermes_home()))
        display = display_hermes_home()
        portable_root = get_portable_app_root()
        ok_home = actual.lower() == expected_home.lower()
        _check("HERMES_HOME matches app/home", ok_home, f"expected={expected_home} actual={actual}") or failures.append(
            "hermes_home mismatch"
        )
        _check("display_hermes_home is portable path", "/app/" in display.replace("\\", "/"), display) or failures.append(
            "display path"
        )
        if portable_root:
            _check(
                "portable app root detected",
                os.path.normpath(str(portable_root)).lower() == os.path.normpath(app_root).lower(),
                str(portable_root),
            ) or failures.append("portable root")
    except Exception as exc:
        _check("path consistency imports", False, str(exc))
        failures.append("path consistency")

    if token:
        status, data = _http("GET", "http://127.0.0.1:9119/api/setup/status", token=token)
        if status == 200 and isinstance(data, dict):
            api_home = os.path.normpath(str(data.get("hermes_home") or ""))
            _check(
                "dashboard /api/setup/status hermes_home",
                api_home.lower() == expected_home.lower(),
                api_home,
            ) or failures.append("api hermes_home")
            disp = data.get("hermes_home_display")
            if disp:
                _check(
                    "dashboard hermes_home_display set",
                    "/app/" in str(disp).replace("\\", "/"),
                    disp,
                ) or failures.append("hermes_home_display")
            else:
                print("WARN dashboard hermes_home_display missing (older web_server)")
        else:
            _check("dashboard /api/setup/status", False, f"HTTP {status}") or failures.append("setup status")


def _test_shared_db(app_root: str, failures: list[str]) -> None:
    print("\n=== Shared kanban.db (CLI) ===")
    home = os.path.join(app_root, "home")
    agent = os.path.join(app_root, "runtime", "hermes-agent")
    os.environ["HERMES_HOME"] = home
    if agent not in sys.path:
        sys.path.insert(0, agent)
    try:
        from hermes_cli import kanban_db as kb

        kb._INITIALIZED_PATHS.clear()
        with kb.connect() as conn:
            tasks = kb.list_tasks(conn)
        path = kb.kanban_db_path()
        _check("CLI kanban_db.connect + list_tasks", True, f"db={path} tasks={len(tasks)}")
    except Exception as exc:
        _check("CLI kanban_db", False, str(exc))
        failures.append("cli kanban_db")


def main() -> int:
    app_root = _app_root()
    if not os.path.isfile(os.path.join(app_root, "runtime", "python311", "python.exe")):
        app_root = os.path.join(os.path.dirname(app_root), "app")

    failures: list[str] = []

    print("=== Kanban all-UI smoke ===")
    print(f"app_root={app_root}")

    for name, url in (
        ("webui-health", "http://127.0.0.1:8787/health"),
        ("dashboard", "http://127.0.0.1:9119/"),
    ):
        try:
            status, _ = _http_raw("GET", url, timeout=6.0)
            _check(f"service {name}", status == 200, f"HTTP {status}") or failures.append(name)
        except Exception as exc:
            _check(f"service {name}", False, str(exc))
            failures.append(name)

    token = _dashboard_token(app_root)
    if not token:
        print("FAIL dashboard session token (start HermesGo.bat first)")
        failures.append("dashboard token")
    else:
        print(f"OK  dashboard session token ({len(token)} chars)")

    _test_path_consistency(app_root, failures, token)
    _test_webui(failures)
    if token:
        _test_dashboard(failures, token)
        _test_desktop(failures, token)
    _test_shared_db(app_root, failures)

    print("\n=== Summary ===")
    if failures:
        print(f"FAILED: {len(failures)} check(s): {', '.join(failures)}")
        return 1
    print("ALL KANBAN UI CHECKS PASSED")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
