"""Smoke-test Hermes Desktop: backend must accept --tui and listen on 9120-9199."""
from __future__ import annotations

import os
import subprocess
import sys
import time
import urllib.error
import urllib.request


def _app_root() -> str:
    override = os.environ.get("HERMESGO_TEST_APP_ROOT", "").strip()
    if override:
        return override
    here = os.path.dirname(os.path.abspath(__file__))
    return os.path.abspath(os.path.join(here, ".."))


def _http_ok(url: str, timeout: float = 6.0) -> bool:
    try:
        with urllib.request.urlopen(url, timeout=timeout) as resp:
            return 200 <= resp.status < 400
    except Exception:
        return False


def main() -> int:
    app = _app_root()
    py = os.path.join(app, "runtime", "python311", "python.exe")
    desktop_exe = os.path.join(app, "runtime", "hermes-desktop", "Hermes.exe")
    home = os.path.join(app, "home")
    log_path = os.path.join(home, "logs", "desktop.log")

    if not os.path.isfile(py):
        print(f"FAIL missing python: {py}")
        return 1
    if not os.path.isfile(desktop_exe):
        print(f"SKIP desktop not bundled: {desktop_exe}")
        return 0

    env = os.environ.copy()
    env["HERMES_HOME"] = home
    env["HERMES_DESKTOP_HERMES_ROOT"] = os.path.join(app, "runtime", "hermes-agent")
    env["HERMES_DESKTOP_PYTHON"] = py

    help_out = subprocess.check_output(
        [py, "-m", "hermes_cli.main", "dashboard", "--help"],
        env=env,
        text=True,
        errors="replace",
    )
    if "--tui" not in help_out:
        print("FAIL dashboard CLI missing --tui (Desktop cannot boot)")
        return 1
    print("OK dashboard CLI supports --tui")

    if os.path.isfile(log_path):
        try:
            os.remove(log_path)
        except OSError:
            pass

    proc = subprocess.Popen(
        [desktop_exe],
        cwd=os.path.dirname(desktop_exe),
        env=env,
    )
    print(f"OK started Hermes.exe pid={proc.pid}")

    deadline = time.time() + 60
    ready = False
    while time.time() < deadline:
        if os.path.isfile(log_path):
            text = open(log_path, encoding="utf-8", errors="replace").read()
            if "unrecognized arguments: --tui" in text:
                proc.terminate()
                print("FAIL desktop.log shows --tui not supported")
                return 1
            if "Hermes backend is ready" in text or "backend is ready" in text:
                ready = True
                break
        if proc.poll() is not None:
            break
        time.sleep(1)

    if not ready:
        proc.terminate()
        print("FAIL desktop backend not ready within 60s")
        return 1
    print("OK desktop backend ready in log")

    for port in range(9120, 9200):
        if _http_ok(f"http://127.0.0.1:{port}/"):
            print(f"OK embedded dashboard HTTP on port {port}")
            proc.terminate()
            return 0

    proc.terminate()
    print("FAIL no HTTP listener on 9120-9199")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
