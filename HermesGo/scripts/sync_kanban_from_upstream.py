"""Sync Kanban assets from NousResearch/hermes-agent main into bundled runtime.

Copies plugins/kanban, hermes_cli kanban_* modules, tools/kanban_tools.py,
and skills/devops/kanban-{worker,orchestrator} into HermesGo/runtime/hermes-agent.
"""
from __future__ import annotations

import os
import shutil
import sys
import tempfile
import urllib.request
import zipfile

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
HERMESGO_ROOT = os.path.dirname(SCRIPT_DIR)
AGENT_DST = os.path.join(HERMESGO_ROOT, "runtime", "hermes-agent")
UPSTREAM_ZIP = "https://github.com/NousResearch/hermes-agent/archive/refs/heads/main.zip"

KANBAN_CLI_FILES = (
    "kanban.py",
    "kanban_db.py",
    "kanban_decompose.py",
    "kanban_specify.py",
    "kanban_diagnostics.py",
    "kanban_swarm.py",
)

SKILL_DIRS = (
    "devops/kanban-worker",
    "devops/kanban-orchestrator",
)


def _download_upstream(tmp: str) -> str:
    zip_path = os.path.join(tmp, "hermes-agent-main.zip")
    print(f"Downloading {UPSTREAM_ZIP} ...")
    urllib.request.urlretrieve(UPSTREAM_ZIP, zip_path)
    extract = os.path.join(tmp, "extract")
    os.makedirs(extract, exist_ok=True)
    with zipfile.ZipFile(zip_path) as zf:
        zf.extractall(extract)
    root = os.path.join(extract, "hermes-agent-main")
    if not os.path.isdir(root):
        raise SystemExit("unexpected zip layout: hermes-agent-main/ missing")
    return root


def _copytree(src: str, dst: str) -> None:
    if os.path.isdir(dst):
        shutil.rmtree(dst)
    shutil.copytree(src, dst)


def sync(src_root: str, dst: str = AGENT_DST) -> None:
    plugin_src = os.path.join(src_root, "plugins", "kanban")
    plugin_dst = os.path.join(dst, "plugins", "kanban")
    if not os.path.isdir(plugin_src):
        raise SystemExit(f"missing upstream plugin: {plugin_src}")
    _copytree(plugin_src, plugin_dst)
    print(f"  plugins/kanban -> {plugin_dst}")

    cli_src = os.path.join(src_root, "hermes_cli")
    cli_dst = os.path.join(dst, "hermes_cli")
    for name in KANBAN_CLI_FILES:
        shutil.copy2(os.path.join(cli_src, name), os.path.join(cli_dst, name))
        print(f"  hermes_cli/{name}")

    tools_dst = os.path.join(dst, "tools")
    os.makedirs(tools_dst, exist_ok=True)
    shutil.copy2(
        os.path.join(src_root, "tools", "kanban_tools.py"),
        os.path.join(tools_dst, "kanban_tools.py"),
    )
    print("  tools/kanban_tools.py")

    skills_dst = os.path.join(dst, "skills")
    for rel in SKILL_DIRS:
        s = os.path.join(src_root, "skills", rel)
        d = os.path.join(skills_dst, rel)
        _copytree(s, d)
        print(f"  skills/{rel}")


def main() -> int:
    src_override = os.environ.get("HERMES_AGENT_SRC", "").strip()
    if src_override and os.path.isdir(src_override):
        print(f"Using HERMES_AGENT_SRC={src_override}")
        sync(src_override)
        return 0

    with tempfile.TemporaryDirectory(prefix="hg-kanban-sync-") as tmp:
        sync(_download_upstream(tmp))
    print("Kanban sync complete.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
