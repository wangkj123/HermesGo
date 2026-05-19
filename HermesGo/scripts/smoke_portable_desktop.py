"""Smoke-test Hermes Desktop via HermesDesktop.bat (user path)."""
from __future__ import annotations

import os
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


def _desktop_process_running(desktop_exe: str) -> bool:
    try:
        ps_exe = os.path.join(
            os.environ.get("SystemRoot", r"C:\Windows"),
            "System32",
            "WindowsPowerShell",
            "v1.0",
            "powershell.exe",
        )
        ps = subprocess.run(
            [
                ps_exe,
                "-NoProfile",
                "-Command",
                (
                    "Get-Process -Name Hermes -ErrorAction SilentlyContinue | "
                    "Where-Object { $_.Path -eq '" + desktop_exe.replace("'", "''") + "' } | "
                    "Select-Object -First 1 -ExpandProperty Id"
                ),
            ],
            capture_output=True,
            text=True,
            errors="replace",
            timeout=10,
        )
    except Exception:
        return False
    return ps.returncode == 0 and bool(ps.stdout.strip())


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
    # DesktopOnly must launch Hermes.exe even when a parent shell set headless for CI.
    env.pop("HERMESGO_HEADLESS", None)
    env.pop("HERMESGO_ALLOW_HEADLESS", None)

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

    remote_ready = False
    local_ready = False
    if os.path.isfile(log_path):
        text = Path(log_path).read_text(encoding="utf-8", errors="replace")
        if "unrecognized arguments: --tui" in text:
            print("FAIL --tui error in desktop.log")
            return 1
        if "backend is ready" not in text and "Desktop boot failed" in text:
            print("FAIL boot failed in desktop.log")
            return 1
        remote_ready = "Remote Hermes backend is ready" in text
        local_ready = "backend is ready" in text and not remote_ready

    embedded_port = None
    if local_ready:
        for port in range(9120, 9200):
            if _http_ok(f"http://127.0.0.1:{port}/"):
                embedded_port = port
                print(f"OK embedded dashboard HTTP {port}")
                break
        if embedded_port is None:
            print("FAIL local Desktop backend log exists but no listener 9120-9199")
            return 1
    elif remote_ready or _desktop_process_running(desktop_exe):
        if not _http_ok("http://127.0.0.1:9119/"):
            print("FAIL Desktop remote mode needs Dashboard HTTP 9119")
            return 1
        print("OK desktop remote backend HTTP 9119")
    else:
        print("FAIL desktop readiness not observed in remote or local mode")
        return 1

    # Gateway must be alive under portable HERMES_HOME (launcher starts it before Desktop).
    home = os.path.join(app, "home")
    os.environ["HERMES_HOME"] = home
    agent_root = os.path.join(app, "runtime", "hermes-agent")
    if os.path.isdir(agent_root):
        sys.path.insert(0, agent_root)
        try:
            from gateway.status import get_running_pid

            gw_pid = get_running_pid()
            if not gw_pid:
                print("FAIL local gateway not running (gateway.pid / process check)")
                return 1
            print(f"OK local gateway pid={gw_pid}")
        except Exception as exc:
            print(f"WARN local gateway check: {exc}")

    check_script = os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "check_dashboard_gateway.py"
    )
    if os.path.isfile(check_script):
        env = os.environ.copy()
        env["HERMES_RUNTIME_DIR"] = agent_root
        env["HERMES_DASHBOARD_URL"] = "http://127.0.0.1:9119/"
        for attempt in range(15):
            rc = subprocess.run(
                [sys.executable, check_script],
                env=env,
                capture_output=True,
                text=True,
            ).returncode
            if rc == 0:
                print("OK dashboard API gateway_running=true")
                break
            time.sleep(1)
        else:
            print("FAIL dashboard API gateway_running=false after 15s (restart Dashboard via bat)")
            return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
