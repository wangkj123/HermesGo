"""Smoke-test Hermes Desktop via HermesDesktop.bat (user path)."""
from __future__ import annotations

import os
import subprocess
import sys
import time
import urllib.request


def _package_root() -> str:
    override = os.environ.get("HERMESGO_TEST_PACKAGE_ROOT", "").strip()
    if override:
        return override
    here = os.path.dirname(os.path.abspath(__file__))
    return os.path.abspath(os.path.join(here, ".."))


def _app_root(package: str) -> str:
    app = os.path.join(package, "app")
    if os.path.isfile(os.path.join(app, "runtime", "python311", "python.exe")):
        return app
    if os.path.isfile(os.path.join(package, "runtime", "python311", "python.exe")):
        return package
    return app


def _http_ok(url: str) -> bool:
    try:
        with urllib.request.urlopen(url, timeout=6) as resp:
            return 200 <= resp.status < 400
    except Exception:
        return False


def main() -> int:
    package = _package_root()
    app = _app_root(package)
    bat = os.path.join(package, "HermesDesktop.bat")
    py = os.path.join(app, "runtime", "python311", "python.exe")
    desktop_exe = os.path.join(app, "runtime", "hermes-desktop", "Hermes.exe")
    log_path = os.path.join(app, "home", "logs", "desktop.log")

    if not os.path.isfile(bat):
        print(f"FAIL missing {bat}")
        return 1
    if not os.path.isfile(desktop_exe):
        print(f"SKIP desktop not bundled")
        return 0

    # Import profile auth on first run (same as launcher)
    home = os.path.join(app, "home")
    auth = os.path.join(home, "auth.json")
    profile_auth = os.path.join(os.path.expanduser("~"), ".hermes", "auth.json")
    if not os.path.isfile(auth) and os.path.isfile(profile_auth):
        os.makedirs(home, exist_ok=True)
        import shutil

        shutil.copy2(profile_auth, auth)
        print(f"OK seeded auth.json from profile")

    env = os.environ.copy()
    env["HERMESGO_TEST_PACKAGE_ROOT"] = package

    if os.path.isfile(log_path):
        try:
            os.remove(log_path)
        except OSError:
            pass

    ps = os.path.join(os.environ.get("SystemRoot", r"C:\Windows"), "System32", "WindowsPowerShell", "v1.0", "powershell.exe")
    print(f"RUN {bat}")
    proc = subprocess.run(
        [ps, "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", f"& '{bat}'"],
        cwd=package,
        env=env,
        capture_output=True,
        text=True,
        errors="replace",
        timeout=120,
    )
    out = (proc.stdout or "") + (proc.stderr or "")
    if out.strip():
        print(out[-2000:])

    if proc.returncode != 0:
        print(f"FAIL HermesDesktop.bat exit {proc.returncode}")
        return 1
    print("OK HermesDesktop.bat exit 0")

    if os.path.isfile(log_path):
        text = open(log_path, encoding="utf-8", errors="replace").read()
        if "unrecognized arguments: --tui" in text:
            print("FAIL --tui error in desktop.log")
            return 1
        if "backend is ready" not in text and "Desktop boot failed" in text:
            print("FAIL boot failed in desktop.log")
            return 1

    for port in range(9120, 9200):
        if _http_ok(f"http://127.0.0.1:{port}/"):
            print(f"OK embedded dashboard HTTP {port}")
            return 0

    print("FAIL no listener 9120-9199 after bat")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
