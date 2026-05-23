"""
Slim portable ZIP: cloud / API-first HermesGo (CLI + Dashboard + WebUI).

Excludes the bulk of the 2.4GB+ "full" tree:
  - Duplicate dev mirror at HermesGo root (agent/, gateway/, tests/, …) — not used at runtime
  - runtime/ollama/ (~1.5GB bundled Ollama app)
  - data/ollama/models/ (~1.6GB Gemma blobs)
  - installers/ (e.g. ollama zip)
  - create_hermes_go, exports, workspaces, …

Runtime uses only: runtime/python311, runtime/hermes-agent, runtime/hermes-webui, runtime/bin.
"""
from __future__ import annotations

import datetime
import os
import shutil
import sys
import zipfile

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SCRIPT_DIR)
from packaging_release import (
    RELEASE_TAG,
    SLIM_VERSION,
    ensure_runtime_version,
    prune_old_slim_zips,
    read_runtime_version,
    stamp_readme_release_tag,
)
from packaging_safe import assert_zip_has_no_reserved_entries, is_windows_reserved_name, should_skip_pack_path
from packaging_sync import resolve_test_package_root, sync_test_package_from_zip

# Avoid shadowing stdlib ``packaging`` — load HermesGo/packaging/bundled_skills.py explicitly.
import importlib.util as _importlib_util

_bundled_skills_path = os.path.join(SCRIPT_DIR, "packaging", "bundled_skills.py")
_spec = _importlib_util.spec_from_file_location("hermesgo_bundled_skills", _bundled_skills_path)
_bundled_mod = _importlib_util.module_from_spec(_spec)
assert _spec and _spec.loader
_spec.loader.exec_module(_bundled_mod)
stage_bundled_optional_skills = _bundled_mod.stage_bundled_optional_skills

OUT_DIR = os.path.join(os.path.dirname(SCRIPT_DIR), "dist")
DT = datetime.datetime.now().strftime("%Y.%m.%d-%H%M%S")
VERSION = SLIM_VERSION
ZIP_NAME = f"HermesGo-{DT}-{RELEASE_TAG}.zip"
ZIP_PATH = os.path.join(OUT_DIR, ZIP_NAME)

DESKTOP_ASAR_MARKERS = (
    "scrollToIndex(t,{align:`end`})",
    "mergePortableCredentialsIntoShellEnv",
)


def _desktop_asar_path() -> str | None:
    candidate = os.path.join(
        SCRIPT_DIR, "runtime", "hermes-desktop", "resources", "app.asar"
    )
    return candidate if os.path.isfile(candidate) else None


def _desktop_patches_already_in_asar() -> bool:
    """True when scroll + portable-shell patches are already applied (no npx needed)."""
    asar = _desktop_asar_path()
    if not asar:
        return False
    try:
        with open(asar, "rb") as fh:
            text = fh.read().decode("utf-8", errors="ignore")
    except OSError:
        return False
    return all(marker in text for marker in DESKTOP_ASAR_MARKERS)


# Package root: launcher entry only (matches create_hermes_go green layout).
SLIM_ROOT_FILES = (
    "HermesGo.exe",
    "README.txt",
    "HermesGo.bat",
    "HermesDesktop.bat",
    "HermesWebUI.bat",
    "HermesVSCode.bat",
)

# Under HermesGo/app/ — not shipped at package root.
SLIM_APP_SCRIPT_FILES = (
    "Start-HermesGo.ps1",
    "Verify-HermesGo.ps1",
    "Verify-HermesGo.bat",
    "Verify-HermesGo-Retry.ps1",
    "Switch-HermesGoModel.ps1",
    "Switch-HermesGoModel.bat",
)

SLIM_DEV_SCRIPT_FILES = (
    "Ensure-HermesGoGlobalPath.ps1",
    "Install-HermesVSCode.ps1",
    "Restart-HermesGoServices.ps1",
    "check_dashboard_gateway.py",
    "smoke_portable_connect.py",
    "smoke_portable_desktop.py",
    "smoke_portable_acp.py",
    "smoke_kanban_all_ui.py",
    "smoke_kanban_api.py",
    "smoke_hello_all_ui.py",
    "smoke_web_search_desktop.py",
    "probe_gateway_tools.py",
)

SLIM_APP_TOOL_FILES = ("codex.cmd",)

BUILDER_ASSETS = os.path.join(
    os.path.dirname(SCRIPT_DIR), "create_hermes_go", "assets"
)

# Trees to pack (relative to HermesGo/)
SLIM_SUBTREES = (
    "runtime/python311",
    "runtime/hermes-agent",
    "runtime/hermes-webui",
    "runtime/hermes-desktop",
    "runtime/bin",
)

# Only skip dirs safe at ANY depth. Do NOT use generic names like "sessions" — they
# appear inside venv/site-packages and would delete most dependencies from the zip.
SKIP_DIR_NAMES = {
    "__pycache__",
    ".git",
    ".pytest_cache",
    "node_modules",
}

SKIP_FILES = {
    "state.db",
    "state.db-shm",
    "state.db-wal",
    "kanban.db",
    "models_dev_cache.json",
    "interrupt_debug.log",
    "auth.json",
    "auth.lock",
    "portable-defaults.txt",
    "memories",
    "HermesGo-debug.txt",
}


def _under_models(rel_norm: str) -> bool:
    return rel_norm.startswith("data/ollama/models/") or rel_norm == "data/ollama/models"


def _under_ollama_runtime(rel_norm: str) -> bool:
    return rel_norm.startswith("runtime/ollama/") or rel_norm == "runtime/ollama"


def _under_installers(rel_norm: str) -> bool:
    return rel_norm.startswith("installers/") or rel_norm == "installers"


def add_tree(zf: zipfile.ZipFile, base: str, rel_prefix: str) -> tuple[int, int]:
    """Add files under base (absolute) as HermesGo/app/{rel_prefix}/..."""
    count = 0
    total = 0
    if not os.path.isdir(base):
        return count, total
    for root, dirs, files in os.walk(base):
        dirs[:] = [
            d
            for d in dirs
            if d not in SKIP_DIR_NAMES and not is_windows_reserved_name(d)
        ]
        rel_root = os.path.relpath(root, SCRIPT_DIR).replace("\\", "/")
        if rel_root == "runtime/hermes-agent" and "tests" in dirs:
            dirs.remove("tests")
        if rel_root == "runtime/hermes-webui" and "tests" in dirs:
            dirs.remove("tests")
        for fname in files:
            if fname in SKIP_FILES or is_windows_reserved_name(fname):
                continue
            src = os.path.join(root, fname)
            sub = os.path.relpath(src, base).replace("\\", "/")
            rel_full = f"{rel_prefix}/{sub}".replace("//", "/") if rel_prefix else sub

            if (
                _under_models(rel_full)
                or _under_ollama_runtime(rel_full)
                or _under_installers(rel_full)
                or should_skip_pack_path(rel_full)
            ):
                continue

            st = os.path.getsize(src)
            arc = f"HermesGo/app/{rel_full}"
            zf.write(src, arc)
            count += 1
            total += st
    return count, total


def main() -> int:
    os.makedirs(OUT_DIR, exist_ok=True)
    ensure_runtime_version(VERSION)
    readme_path = os.path.join(SCRIPT_DIR, "README.txt")
    if os.path.isfile(readme_path):
        stamp_readme_release_tag(readme_path, VERSION, RELEASE_TAG)
    runtime_ver = read_runtime_version()
    if runtime_ver != VERSION:
        print(f"ERROR: runtime version {runtime_ver!r} != build {VERSION!r}")
        return 1

    import subprocess

    if _desktop_patches_already_in_asar():
        print("Desktop app.asar already patched — skipping patch_desktop_*.py (npx not required)")
    else:
        for patch_name in ("patch_desktop_scroll.py", "patch_desktop_portable_shell.py"):
            patch_script = os.path.join(SCRIPT_DIR, "scripts", patch_name)
            if not os.path.isfile(patch_script):
                continue
            print(f"Patching desktop ({patch_name}) before zip...")
            rc = subprocess.call([sys.executable, patch_script], cwd=SCRIPT_DIR)
            if rc != 0:
                if _desktop_patches_already_in_asar():
                    print(f"WARN: {patch_name} failed but app.asar markers present — continuing")
                    continue
                print(f"ERROR: {patch_name} failed (install Node.js/npx or pre-patch app.asar)")
                return rc

    extras_install = os.path.join(SCRIPT_DIR, "packaging", "install_slim_runtime_extras.py")
    if os.path.isfile(extras_install):
        print("Installing slim runtime extras (acp + ddgs) into bundled python311...")
        extras_rc = subprocess.call([sys.executable, extras_install], cwd=SCRIPT_DIR)
        if extras_rc != 0:
            print("ERROR: slim runtime extras install failed — zip would download on first boot")
            return extras_rc

    ps1_path = os.path.join(SCRIPT_DIR, "Start-HermesGo.ps1")
    with open(ps1_path, "r", encoding="utf-8") as f:
        ps1_fixed = f.read()

    included = 0
    included_size = 0

    with zipfile.ZipFile(ZIP_PATH, "w", zipfile.ZIP_DEFLATED, compresslevel=5) as zf:
        for name in SLIM_ROOT_FILES:
            if is_windows_reserved_name(name):
                continue
            p = os.path.join(SCRIPT_DIR, name)
            if not os.path.isfile(p):
                print(f"WARN: missing root file: {name}")
                continue
            arc = f"HermesGo/{name}"
            zf.write(p, arc)
            included += 1
            included_size += os.path.getsize(p)

        for name in SLIM_APP_SCRIPT_FILES:
            if is_windows_reserved_name(name):
                continue
            p = os.path.join(SCRIPT_DIR, name)
            if not os.path.isfile(p):
                continue
            arc = f"HermesGo/app/scripts/{name}"
            if name == "Start-HermesGo.ps1":
                data = ps1_fixed.encode("utf-8")
                zf.writestr(
                    zipfile.ZipInfo(arc, datetime.datetime.now().timetuple()[:6]),
                    data,
                )
                included += 1
                included_size += len(data)
            else:
                zf.write(p, arc)
                included += 1
                included_size += os.path.getsize(p)

        for name in SLIM_DEV_SCRIPT_FILES:
            if is_windows_reserved_name(name):
                continue
            p = os.path.join(SCRIPT_DIR, "scripts", name)
            if not os.path.isfile(p):
                continue
            arc = f"HermesGo/app/scripts/{name}"
            zf.write(p, arc)
            included += 1
            included_size += os.path.getsize(p)

        for name in SLIM_APP_TOOL_FILES:
            p = os.path.join(SCRIPT_DIR, name)
            if not os.path.isfile(p):
                continue
            arc = f"HermesGo/app/tools/{name}"
            zf.write(p, arc)
            included += 1
            included_size += os.path.getsize(p)

        for rel in ("HermesGo-logo.png", os.path.join("icons", "HermesGo.ico")):
            src = os.path.join(BUILDER_ASSETS, rel.replace("/", os.sep))
            if not os.path.isfile(src):
                print(f"WARN: missing asset (run Compile-HermesGoBootstrap.ps1 first): {src}")
                continue
            arc = f"HermesGo/app/assets/{rel.replace(os.sep, '/')}"
            zf.write(src, arc)
            included += 1
            included_size += os.path.getsize(src)

        for sub in SLIM_SUBTREES:
            abs_base = os.path.join(SCRIPT_DIR, sub)
            c, s = add_tree(zf, abs_base, sub.replace("\\", "/"))
            included += c
            included_size += s

        skills_stage = os.path.join(OUT_DIR, ".slim-skills-stage")
        if os.path.isdir(skills_stage):
            shutil.rmtree(skills_stage, ignore_errors=True)
        os.makedirs(skills_stage, exist_ok=True)
        skill_count, skill_missing = stage_bundled_optional_skills(SCRIPT_DIR, skills_stage)
        if skill_missing:
            print(f"WARN: missing optional-skills to bundle: {', '.join(skill_missing)}")
        for root, dirs, files in os.walk(os.path.join(skills_stage, "optional-skills")):
            dirs[:] = [d for d in dirs if d not in SKIP_DIR_NAMES]
            for fname in files:
                src = os.path.join(root, fname)
                rel = os.path.relpath(src, skills_stage).replace("\\", "/")
                arc = f"HermesGo/app/{rel}"
                zf.write(src, arc)
                included += 1
                included_size += os.path.getsize(src)
        shutil.rmtree(skills_stage, ignore_errors=True)
        print(f"Bundled optional-skills: {skill_count} skill(s)")

        # Create clean runtime state dirs (green package, no local history/secrets).
        slim_config_template = os.path.join(SCRIPT_DIR, "packaging", "config.yaml.slim-default")
        if os.path.isfile(slim_config_template):
            zf.write(slim_config_template, "HermesGo/app/home/config.yaml.slim-default")

        for d in (
            "HermesGo/app/home/",
            "HermesGo/app/logs/",
            "HermesGo/app/logs/tmp/",
            "HermesGo/app/workspace/",
            "HermesGo/app/webui-data/",
            "HermesGo/app/data/",
            "HermesGo/app/data/ollama/",
            "HermesGo/app/data/ollama/models/",
        ):
            zf.writestr(zipfile.ZipInfo(d, datetime.datetime.now().timetuple()[:6]), b"")

        green_marker = (
            "hermesgo-green-portable=1\n"
            "strict=1\n"
            "windows_only=1\n"
            "disable_wsl=1\n"
            "configure_on_exe=1\n"
            "bundled_extras=acp,ddgs,web_search\n"
            "no_pip_download=1\n"
        ).encode("utf-8")
        zf.writestr(
            zipfile.ZipInfo(
                "HermesGo/app/.hermesgo-green",
                datetime.datetime.now().timetuple()[:6],
            ),
            green_marker,
        )

        slim_readme = (
            "# HermesGo slim package\n\n"
            "This archive contains portable Python, Hermes Agent, and Hermes WebUI only.\n\n"
            "Not included (use the full bundle if you need them):\n"
            "- Bundled Ollama runtime (`runtime/ollama`)\n"
            "- Pre-downloaded Ollama model blobs (`data/ollama/models`)\n"
            "- Large optional installers under `installers/`\n"
            "- Duplicate development copy of agent sources at package root\n\n"
            "This package intentionally starts with clean empty runtime state dirs\n"
            "(`app/home`, `app/logs`, `app/workspace`, `app/webui-data`, `app/data`) so no\n"
            "chat history or local secrets are shipped.\n\n"
            "Strict portable mode (default): all config/auth/logs stay under `app/home` on this\n"
            "copy only — no writes to host `~/.hermes` or User PATH. Use `app/runtime/bin/hermes.cmd`.\n"
            "Hermes green runs on native Windows + bundled `python.exe` only (no WSL dependency;\n"
            "HERMES_DISABLE_WSL affects Hermes processes only, not Cursor). Target users\n"
            "typically do not have WSL installed.\n\n"
            "Cloud API keys (e.g. DeepSeek) work as in the full package. "
            "Bundled optional-skills (duckduckgo-search, domain-intel, docker-management, …) "
            "provide free web search when FIRECRAWL/TAVILY keys are not set.\n"
            "For local Gemma/Ollama, install Ollama separately or add models under "
            "`app/data/ollama/models`.\n\n"
            f"v{VERSION}: sync verify, dist prune, preserve workspace/webui-data on exe update.\n"
            "Optional: `runtime/hermes-desktop/` (portable Electron, run `HermesDesktop.bat`).\n"
            "Package root keeps `HermesGo.exe`, `README.txt`, launchers, and `HermesVSCode.bat`;\n"
            "scripts, tools, assets, and runtime live under `app/`.\n"
            "VS Code green: run `HermesVSCode.bat` (see app/docs/VSCODE-GREEN.md).\n"
        )
        zf.writestr(
            zipfile.ZipInfo(
                "HermesGo/app/docs/PACKAGE-SLIM.md",
                datetime.datetime.now().timetuple()[:6],
            ),
            slim_readme.encode("utf-8"),
        )

        vscode_green_doc = os.path.join(SCRIPT_DIR, "packaging", "docs", "VSCODE-GREEN.md")
        if os.path.isfile(vscode_green_doc):
            zf.write(vscode_green_doc, "HermesGo/app/docs/VSCODE-GREEN.md")
            included += 1
            included_size += os.path.getsize(vscode_green_doc)

    with zipfile.ZipFile(ZIP_PATH, "r") as zf:
        assert_zip_has_no_reserved_entries(zf.namelist())

    verify_extras = os.path.join(SCRIPT_DIR, "packaging", "verify_zip_offline_extras.py")
    if os.path.isfile(verify_extras):
        verify_rc = subprocess.call([sys.executable, verify_extras, ZIP_PATH], cwd=SCRIPT_DIR)
        if verify_rc != 0:
            print("ERROR: zip missing offline-bundled acp/ddgs — aborting")
            return verify_rc

    verify_web = os.path.join(SCRIPT_DIR, "packaging", "verify_zip_web_search.py")
    if os.path.isfile(verify_web):
        verify_rc = subprocess.call([sys.executable, verify_web, ZIP_PATH], cwd=SCRIPT_DIR)
        if verify_rc != 0:
            print("ERROR: zip missing working web_search (ddgs) — aborting")
            return verify_rc

    zsize = os.path.getsize(ZIP_PATH)
    print(f"Building: {ZIP_NAME}")
    print(f"Files: {included}, raw ~{included_size / 1024 / 1024:.1f} MB")
    print(f"ZIP: {zsize / 1024 / 1024:.1f} MB")
    print(f"Done: {ZIP_PATH}")
    removed = prune_old_slim_zips(OUT_DIR, ZIP_PATH)
    if removed:
        print(f"Pruned {removed} older slim zip(s) from dist/")

    if os.environ.get("HERMESGO_SKIP_TEST_SYNC", "").strip().lower() in ("1", "true", "yes"):
        print("Test sync skipped (HERMESGO_SKIP_TEST_SYNC)")
        return 0

    test_root = resolve_test_package_root()
    print(f"Syncing test package -> {test_root}")
    try:
        sync_test_package_from_zip(ZIP_PATH, test_root)
    except OSError as exc:
        print(f"ERROR: test package sync failed: {exc}")
        print("Stop HermesGo python/Hermes.exe processes and retry, or set HERMESGO_SKIP_TEST_SYNC=1")
        return 1
    except RuntimeError as exc:
        print(f"ERROR: {exc}")
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
