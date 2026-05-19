"""Smoke-test portable green package: services up + model provider connectivity."""
from __future__ import annotations

import os
import sys
import urllib.error
import urllib.request


def _app_root_from_env() -> str:
    override = os.environ.get("HERMESGO_TEST_APP_ROOT", "").strip()
    if override:
        return override
    here = os.path.dirname(os.path.abspath(__file__))
    return os.path.abspath(os.path.join(here, ".."))


def _portable_path(app_root: str) -> str:
    parts = [
        os.path.join(app_root, "runtime", "bin"),
        os.path.join(app_root, "runtime", "python311"),
        os.path.join(app_root, "runtime", "python311", "Scripts"),
        app_root,
    ]
    windir = os.environ.get("WINDIR", r"C:\Windows")
    sys32 = os.path.join(windir, "System32")
    if os.path.isdir(sys32):
        parts.append(sys32)
    return os.pathsep.join(parts)


def _http_get(url: str, timeout: float = 10.0, token: str | None = None) -> tuple[int, bytes]:
    headers = {}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(url, method="GET", headers=headers)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.status, resp.read()


def _dashboard_token(app_root: str) -> str | None:
    index = os.path.join(app_root, "runtime", "hermes-agent", "hermes_cli", "web_dist", "index.html")
    if not os.path.isfile(index):
        return None
    try:
        status, body = _http_get("http://127.0.0.1:9119/env?quick=1", timeout=8.0)
    except Exception:
        return None
    if status != 200:
        return None
    text = body.decode("utf-8", errors="replace")
    marker = "__HERMES_SESSION_TOKEN__=\""
    start = text.find(marker)
    if start < 0:
        return None
    start += len(marker)
    end = text.find("\"", start)
    if end < 0:
        return None
    return text[start:end]


def _api_post_json(url: str, payload: dict, token: str | None) -> tuple[int, dict]:
    import json

    data = json.dumps(payload).encode("utf-8")
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(url, data=data, headers=headers, method="POST")
    with urllib.request.urlopen(req, timeout=30) as resp:
        return resp.status, json.loads(resp.read().decode("utf-8"))


def main() -> int:
    app_root = _app_root_from_env()
    if not os.path.isfile(os.path.join(app_root, "runtime", "python311", "python.exe")):
        app_root = os.path.join(os.path.dirname(app_root), "app")
    home = os.path.join(app_root, "home")
    agent = os.path.join(app_root, "runtime", "hermes-agent")

    os.environ["HERMES_HOME"] = home
    os.environ["PATH"] = _portable_path(app_root)
    os.environ.pop("PYTHONHOME", None)
    os.environ.pop("PYTHONPATH", None)
    sys.path.insert(0, agent)

    failures = 0

    for name, url in (
        ("dashboard", "http://127.0.0.1:9119/"),
        ("webui-health", "http://127.0.0.1:8787/health"),
    ):
        try:
            status, _ = _http_get(url, timeout=8.0)
            print(f"OK {name}: HTTP {status}")
        except Exception as exc:
            print(f"FAIL {name}: {exc}")
            failures += 1

    token = _dashboard_token(app_root)
    if not token:
        print("WARN dashboard token not found in /env HTML (services may still be up)")
    else:
        print("OK dashboard session token extracted")

    from hermes_cli.config import load_config

    cfg = load_config()
    model_cfg = cfg.get("model")
    if isinstance(model_cfg, dict):
        provider = str(model_cfg.get("provider") or "").strip()
        model = str(model_cfg.get("default") or model_cfg.get("name") or "").strip()
    elif isinstance(model_cfg, str):
        provider = ""
        model = model_cfg.strip()
    else:
        provider = ""
        model = ""
    print(f"config provider={provider} model={model}")

    try:
        from hermes_cli.runtime_provider import resolve_runtime_provider

        runtime = resolve_runtime_provider(requested=provider or None)
        api_mode = str(runtime.get("api_mode") or "")
        base_url = str(runtime.get("base_url") or "")
        has_key = bool(str(runtime.get("api_key") or "").strip())
        print(f"OK runtime provider={runtime.get('provider')} api_mode={api_mode} base_url={base_url} has_key={has_key}")

        if token and provider and has_key:
            try:
                status, body = _api_post_json(
                    "http://127.0.0.1:9119/api/providers/test",
                    {"provider_id": provider.replace("_", "-")},
                    token,
                )
            except urllib.error.HTTPError as exc:
                print(f"FAIL /api/providers/test: HTTP {exc.code}")
                failures += 1
            else:
                if status == 200 and body.get("ok"):
                    print(f"OK /api/providers/test: {body}")
                else:
                    print(f"FAIL /api/providers/test: HTTP {status} {body}")
                    failures += 1
        elif token and provider:
            print("WARN /api/providers/test skipped (no API key in portable home)")
        elif has_key and api_mode == "codex_responses":
            print("OK codex credentials resolved (dashboard probe skipped)")
    except Exception as exc:
        print(f"FAIL runtime/connectivity: {exc}")
        failures += 1

    try:
        import json

        status, body = _http_get("http://127.0.0.1:8787/api/kanban/boards", timeout=8.0)
        if status == 200:
            data = json.loads(body.decode("utf-8"))
            boards = data.get("boards") or []
            print(f"OK webui kanban boards: count={len(boards)}")
        else:
            print(f"FAIL webui kanban: HTTP {status}")
            failures += 1
    except Exception as exc:
        print(f"FAIL webui kanban: {exc}")
        failures += 1

    if token:
        try:
            import json

            status, body = _http_get(
                "http://127.0.0.1:9119/api/dashboard/plugins", timeout=8.0, token=token
            )
            if status != 200:
                print(f"FAIL dashboard plugins: HTTP {status}")
                failures += 1
            else:
                plugins = json.loads(body.decode("utf-8"))
                names = [p.get("name") for p in plugins if isinstance(p, dict)]
                if "kanban" not in names:
                    print(f"FAIL dashboard plugins: kanban missing in {names}")
                    failures += 1
                else:
                    print("OK dashboard plugins: kanban registered")

            status, body = _http_get(
                "http://127.0.0.1:9119/api/plugins/kanban/boards", timeout=8.0, token=token
            )
            if status == 200:
                data = json.loads(body.decode("utf-8"))
                boards = data.get("boards") or []
                print(f"OK dashboard kanban boards: count={len(boards)}")
            else:
                print(f"FAIL dashboard kanban API: HTTP {status} {body[:200]!r}")
                failures += 1
        except Exception as exc:
            print(f"FAIL dashboard kanban: {exc}")
            failures += 1
    else:
        print("WARN dashboard kanban skipped (no session token)")

    if failures:
        print(f"FAILED ({failures} checks)")
        return 1
    print("ALL CHECKS PASSED")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
