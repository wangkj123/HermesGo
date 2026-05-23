"""Smoke: HermesGo portable ACP deps + registry + hermes acp import path."""
from __future__ import annotations

import os
import subprocess
import sys


def main() -> int:
    app = os.environ.get("HERMESGO_TEST_APP_ROOT", "").strip()
    if not app:
        print("SKIP: set HERMESGO_TEST_APP_ROOT to app/")
        return 0
    app = os.path.abspath(app)
    py = os.path.join(app, "runtime", "python311", "python.exe")
    agent = os.path.join(app, "runtime", "hermes-agent")
    registry = os.path.join(agent, "acp_registry", "agent.json")
    hermes_cmd = os.path.join(app, "runtime", "bin", "hermes.cmd")

    checks = [
        (py, "python.exe"),
        (registry, "acp_registry/agent.json"),
        (hermes_cmd, "runtime/bin/hermes.cmd"),
    ]
    for path, label in checks:
        if not os.path.isfile(path):
            print(f"FAIL missing {label}: {path}")
            return 1

    env = os.environ.copy()
    env["HERMES_HOME"] = os.path.join(app, "home")
    env["HERMES_PORTABLE_APP_ROOT"] = app
    env["HERMES_DISABLE_WSL"] = "1"

    boot = subprocess.run(
        [
            py,
            "-c",
            (
                "import sys; sys.path.insert(0, r'%s'); "
                "from hermes_cli.portable_bootstrap import ensure_portable_acp_deps; "
                "ensure_portable_acp_deps(); import acp; from acp.schema import AgentCapabilities"
            )
            % agent.replace("\\", "\\\\"),
        ],
        env=env,
        capture_output=True,
        text=True,
    )
    if boot.returncode != 0:
        print("FAIL acp bootstrap:", boot.stderr or boot.stdout)
        return 1

    help_rc = subprocess.run(
        [py, "-m", "hermes_cli.main", "acp", "-h"],
        env=env,
        cwd=agent,
        capture_output=True,
        text=True,
        timeout=30,
    )
    if help_rc.returncode != 0 or "ACP" not in (help_rc.stdout + help_rc.stderr):
        print("FAIL hermes acp -h:", help_rc.stderr or help_rc.stdout)
        return 1

    print("OK portable ACP (acp package + hermes acp)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
