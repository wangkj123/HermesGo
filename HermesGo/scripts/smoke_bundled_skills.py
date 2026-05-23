"""Smoke: slim zip ships optional-skills + ddgs + skills prompt fallback."""
from __future__ import annotations

import os
import subprocess
import sys


def _app_root() -> str:
    override = os.environ.get("HERMESGO_TEST_APP_ROOT", "").strip()
    if override:
        return override
    here = os.path.dirname(os.path.abspath(__file__))
    return os.path.abspath(os.path.join(here, "..", "app"))


def main() -> int:
    app = _app_root()
    py = os.path.join(app, "runtime", "python311", "python.exe")
    agent = os.path.join(app, "runtime", "hermes-agent")
    home = os.path.join(app, "home")

    if not os.path.isfile(py):
        print(f"FAIL: missing {py}")
        return 1

    checks = [
        os.path.join(app, "optional-skills", "research", "duckduckgo-search", "SKILL.md"),
        os.path.join(app, "runtime", "hermes-agent", "hermes_cli", "portable_bundled_skills.py"),
    ]
    for path in checks:
        if not os.path.isfile(path):
            print(f"FAIL: missing {path}")
            return 1
        print(f"OK file: {os.path.relpath(path, app)}")

    slim_default = os.path.join(home, "config.yaml.slim-default")
    if os.path.isfile(slim_default):
        text = open(slim_default, encoding="utf-8").read()
        if "optional-skills/research" not in text:
            print("FAIL: slim-default missing skills.external_dirs")
            return 1
        print("OK slim-default has skills.external_dirs")

    probe = subprocess.run([py, "-m", "pip", "show", "ddgs"], capture_output=True, text=True)
    if probe.returncode != 0:
        print("WARN: ddgs not installed yet (bootstrap should install on first launch)")

    os.environ["HERMES_PORTABLE_APP_ROOT"] = app
    os.environ["HERMES_HOME"] = home
    os.environ["HERMES_PORTABLE_STRICT"] = "1"

    bootstrap = f"""
import sys
sys.path.insert(0, r'{agent}')
from hermes_cli.portable_bootstrap import ensure_portable_exe_ready
print(ensure_portable_exe_ready())
"""
    out = subprocess.run([py, "-c", bootstrap], capture_output=True, text=True, cwd=app)
    print(out.stdout.strip() or out.stderr.strip())
    if out.returncode != 0:
        print("FAIL: portable bootstrap")
        return 1

    probe2 = subprocess.run([py, "-m", "pip", "show", "ddgs"], capture_output=True, text=True)
    if probe2.returncode != 0:
        print("FAIL: ddgs still missing after bootstrap")
        return 1
    print("OK ddgs installed")

    prompt_check = f"""
import sys
sys.path.insert(0, r'{agent}')
from agent.prompt_builder import build_skills_system_prompt
from model_tools import get_tool_definitions
tools = get_tool_definitions(enabled_toolsets=["terminal", "file"], quiet_mode=True)
names = {{t["function"]["name"] for t in tools}}
prompt = build_skills_system_prompt(available_tools=names, available_toolsets={{"terminal", "file"}})
assert "duckduckgo" in prompt.lower(), "duckduckgo skill not in prompt: " + prompt[:400]
print("OK duckduckgo skill active in system prompt (web_search absent)")
"""
    out2 = subprocess.run([py, "-c", prompt_check], capture_output=True, text=True, cwd=app)
    if out2.returncode != 0:
        print(out2.stdout)
        print(out2.stderr)
        print("FAIL: skills prompt check")
        return 1
    print(out2.stdout.strip())

    ddgs_run = subprocess.run(
        [py, "-m", "ddgs", "text", "-k", "HermesGo test", "-m", "2", "-o", "json"],
        capture_output=True,
        text=True,
        timeout=45,
    )
    if ddgs_run.returncode != 0:
        print("WARN: ddgs search failed (network?):", (ddgs_run.stderr or ddgs_run.stdout)[:300])
    else:
        print("OK ddgs CLI search returned data")

    print("smoke_bundled_skills: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
