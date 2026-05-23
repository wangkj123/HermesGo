"""Verify slim zip ships pre-bundled acp/ddgs (no first-boot pip)."""
from __future__ import annotations

import os
import sys
import zipfile

REQUIRED_PREFIXES = (
    "HermesGo/app/runtime/python311/Lib/site-packages/acp/",
    "HermesGo/app/runtime/python311/Lib/site-packages/ddgs/",
    "HermesGo/app/runtime/hermes-agent/acp_registry/agent.json",
    "HermesGo/HermesVSCode.bat",
    "HermesGo/app/docs/VSCODE-GREEN.md",
    "HermesGo/app/scripts/Install-HermesVSCode.ps1",
)


def verify_zip(zip_path: str) -> list[str]:
    errors: list[str] = []
    with zipfile.ZipFile(zip_path, "r") as zf:
        names = set(zf.namelist())
        for prefix in REQUIRED_PREFIXES:
            if not any(n.startswith(prefix) or n == prefix.rstrip("/") for n in names):
                errors.append(f"missing in zip: {prefix}")
        if not any(n.startswith("HermesGo/app/runtime/python311/Lib/site-packages/acp/") for n in names):
            errors.append("no acp package under site-packages")
        if not any(n.startswith("HermesGo/app/runtime/python311/Lib/site-packages/ddgs/") for n in names):
            errors.append("no ddgs package under site-packages")
    return errors


def main() -> int:
    if len(sys.argv) < 2:
        print("Usage: verify_zip_offline_extras.py <path-to.zip>")
        return 2
    zip_path = os.path.abspath(sys.argv[1])
    if not os.path.isfile(zip_path):
        print(f"ERROR: not found: {zip_path}")
        return 1
    errors = verify_zip(zip_path)
    if errors:
        for err in errors:
            print(f"ERROR: {err}")
        return 1
    print(f"OK offline extras verified: {zip_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
