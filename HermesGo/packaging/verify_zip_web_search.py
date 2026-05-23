"""Verify slim zip ships working web_search (ddgs backend in site-packages)."""
from __future__ import annotations

import os
import sys
import zipfile
import tempfile


def verify_zip(zip_path: str) -> list[str]:
    errors: list[str] = []
    with zipfile.ZipFile(zip_path, "r") as zf:
        names = zf.namelist()
        if not any(n.startswith("HermesGo/app/runtime/python311/Lib/site-packages/ddgs/") for n in names):
            errors.append("missing site-packages/ddgs (pip dependency for web_search)")
        wt = "HermesGo/app/runtime/hermes-agent/tools/web_tools.py"
        if wt not in names:
            errors.append(f"missing {wt}")
        else:
            with zf.open(wt) as fh:
                body = fh.read().decode("utf-8", errors="replace")
            if "_ddgs_search" not in body or "use_ddgs" not in body:
                errors.append("web_tools.py missing ddgs fallback (_ddgs_search / use_ddgs)")
        cfg = "HermesGo/app/home/config.yaml.slim-default"
        if cfg in names:
            with zf.open(cfg) as fh:
                slim = fh.read().decode("utf-8", errors="replace")
            if "backend: duckduckgo" not in slim.replace('"', "").replace("'", ""):
                if "duckduckgo" not in slim:
                    errors.append("config.yaml.slim-default missing web.backend duckduckgo")
    return errors


def smoke_installed_tree(app_root: str) -> list[str]:
    """Optional smoke on extracted app/ after sync."""
    errors: list[str] = []
    py = os.path.join(app_root, "runtime", "python311", "python.exe")
    agent = os.path.join(app_root, "runtime", "hermes-agent")
    if not os.path.isfile(py):
        return ["python.exe missing"]
    import subprocess

    rc = subprocess.run(
        [py, "-c", "from ddgs import DDGS"],
        capture_output=True,
        text=True,
    )
    if rc.returncode != 0:
        errors.append("ddgs import failed in bundled python")
        return errors

    code = f"""
import os, sys, json
sys.path.insert(0, r'{agent}')
os.environ['HERMES_HOME'] = r'{os.path.join(app_root, "home")}'
os.environ['HERMES_PORTABLE_APP_ROOT'] = r'{app_root}'
from tools.web_tools import web_search_tool, check_web_api_key
assert check_web_api_key(), 'check_web_api_key false'
raw = web_search_tool('HermesGo web_search smoke', 2)
data = json.loads(raw)
assert data.get('success'), raw[:300]
assert data.get('data', {{}}).get('web'), 'no results'
print('OK web_search smoke')
"""
    env = os.environ.copy()
    env["HERMES_HOME"] = os.path.join(app_root, "home")
    env["HERMES_PORTABLE_APP_ROOT"] = app_root
    rc2 = subprocess.run([py, "-c", code], capture_output=True, text=True, env=env, cwd=agent, timeout=60)
    if rc2.returncode != 0:
        errors.append((rc2.stderr or rc2.stdout or "web_search_tool failed")[:500])
    return errors


def main() -> int:
    if len(sys.argv) < 2:
        print("Usage: verify_zip_web_search.py <zip> [app_root]")
        return 2
    zip_path = os.path.abspath(sys.argv[1])
    errors = verify_zip(zip_path)
    if len(sys.argv) >= 3:
        errors.extend(smoke_installed_tree(os.path.abspath(sys.argv[2])))
    if errors:
        for e in errors:
            print(f"ERROR: {e}")
        return 1
    print(f"OK web_search verified: {zip_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
