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
from packaging_safe import assert_zip_has_no_reserved_entries, is_windows_reserved_name, should_skip_pack_path
from packaging_sync import resolve_test_package_root, sync_test_package_from_zip
OUT_DIR = os.path.join(os.path.dirname(SCRIPT_DIR), "dist")
DT = datetime.datetime.now().strftime("%Y.%m.%d-%H%M%S")
VERSION = "0.14.2"
RELEASE_TAG = f"v{VERSION}-green-3ui-slim"
ZIP_NAME = f"HermesGo-{DT}-{RELEASE_TAG}.zip"
ZIP_PATH = os.path.join(OUT_DIR, ZIP_NAME)

# Package root: launcher entry only (matches create_hermes_go green layout).
SLIM_ROOT_FILES = (
    "HermesGo.exe",
    "README.txt",
    "HermesGo.bat",
    "HermesDesktop.bat",
    "HermesWebUI.bat",
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
    "check_dashboard_gateway.py",
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


def main() -> None:
    os.makedirs(OUT_DIR, exist_ok=True)

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
            "Cloud API keys (e.g. DeepSeek) work as in the full package. "
            "For local Gemma/Ollama, install Ollama separately or add models under "
            "`app/data/ollama/models`.\n\n"
            "v0.14.2: includes Desktop remote binding to Dashboard/gateway plus WebUI board backend.\n"
            "Optional: `runtime/hermes-desktop/` (portable Electron, run `HermesDesktop.bat`).\n"
            "Package root keeps only `HermesGo.exe`, `README.txt`, and the three `.bat` launchers;\n"
            "scripts, tools, assets, and runtime live under `app/`.\n"
        )
        zf.writestr(
            zipfile.ZipInfo(
                "HermesGo/app/docs/PACKAGE-SLIM.md",
                datetime.datetime.now().timetuple()[:6],
            ),
            slim_readme.encode("utf-8"),
        )

    with zipfile.ZipFile(ZIP_PATH, "r") as zf:
        assert_zip_has_no_reserved_entries(zf.namelist())

    zsize = os.path.getsize(ZIP_PATH)
    print(f"Building: {ZIP_NAME}")
    print(f"Files: {included}, raw ~{included_size / 1024 / 1024:.1f} MB")
    print(f"ZIP: {zsize / 1024 / 1024:.1f} MB")
    print(f"Done: {ZIP_PATH}")

    if os.environ.get("HERMESGO_SKIP_TEST_SYNC", "").strip().lower() in ("1", "true", "yes"):
        print("Test sync skipped (HERMESGO_SKIP_TEST_SYNC)")
    else:
        test_root = resolve_test_package_root()
        try:
            sync_test_package_from_zip(ZIP_PATH, test_root)
        except OSError as e:
            print(f"WARN: test package sync failed: {e}")


if __name__ == "__main__":
    main()
