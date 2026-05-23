"""Pre-install slim runtime PyPI extras into bundled python311 (build-time, required).

Bundles offline-capable extras so green package does not pip download on first boot:
  - agent-client-protocol (import acp) — VS Code ACP
  - ddgs — duckduckgo-search skill
"""
from __future__ import annotations

import os
import subprocess
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
HERMES_GO = os.path.dirname(SCRIPT_DIR)
PY = os.path.join(HERMES_GO, "runtime", "python311", "python.exe")
AGENT_ROOT = os.path.join(HERMES_GO, "runtime", "hermes-agent")
INDEX = os.environ.get(
    "HERMESGO_PYPI_INDEX",
    "https://pypi.tuna.tsinghua.edu.cn/simple",
)

# Keep in sync with portable_bundled_skills.py
PACKAGES: tuple[str, ...] = (
    "agent-client-protocol>=0.9.0,<1.0",
    "ddgs",
)


def _pip_show(name: str) -> bool:
    probe = subprocess.run(
        [PY, "-m", "pip", "show", name],
        capture_output=True,
        text=True,
    )
    return probe.returncode == 0


def _package_name(spec: str) -> str:
    name = str(spec).split("==")[0].split("[")[0].strip()
    return name.split(">=")[0].split("<")[0].split("!=")[0].strip()


def install_all() -> int:
    if not os.path.isfile(PY):
        print(f"ERROR: bundled python missing: {PY}")
        return 1

    for spec in PACKAGES:
        name = _package_name(spec)
        if _pip_show(name):
            print(f"OK: {name} already installed")
            continue
        print(f"Installing {spec} (index={INDEX}) ...")
        rc = subprocess.run(
            [PY, "-m", "pip", "install", spec, "-i", INDEX],
        ).returncode
        if rc != 0:
            print(f"ERROR: pip install failed for {spec}")
            return rc

    checks = [
        ("import acp; from acp.schema import AgentCapabilities", "acp"),
        ("import ddgs", "ddgs"),
    ]
    for code, label in checks:
        verify = subprocess.run([PY, "-c", code], capture_output=True, text=True)
        if verify.returncode != 0:
            print(f"ERROR: verify {label} failed:\n{verify.stderr or verify.stdout}")
            return 1

    adapter = subprocess.run(
        [
            PY,
            "-c",
            f"import sys; sys.path.insert(0, r'{AGENT_ROOT}'); "
            "from acp_adapter.entry import main",
        ],
        capture_output=True,
        text=True,
    )
    if adapter.returncode != 0:
        print(f"ERROR: acp_adapter import failed:\n{adapter.stderr or adapter.stdout}")
        return 1

    print("OK: slim runtime extras bundled (acp + ddgs + acp_adapter)")
    return 0


def main() -> int:
    return install_all()


if __name__ == "__main__":
    raise SystemExit(main())
