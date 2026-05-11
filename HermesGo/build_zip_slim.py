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
import zipfile

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
OUT_DIR = os.path.join(os.path.dirname(SCRIPT_DIR), "dist")
DT = datetime.datetime.now().strftime("%Y.%m.%d-%H%M%S")
ZIP_NAME = f"HermesGo-{DT}-DeepSeek-v13-WebUI-slim.zip"
ZIP_PATH = os.path.join(OUT_DIR, ZIP_NAME)

# Only these files from HermesGo root (no duplicate hermes-agent tree at repo root)
SLIM_ROOT_FILES = {
    "HermesGo.bat",
    "HermesWebUI.bat",
    "Start-HermesGo.ps1",
    "Verify-HermesGo.ps1",
    "Verify-HermesGo.bat",
    "Verify-HermesGo-Retry.ps1",
    "Switch-HermesGoModel.ps1",
    "Switch-HermesGoModel.bat",
    "README.md",
    "codex.cmd",
    "HermesGo.exe",
    ".release_notes.md",
    "AGENTS.md",
}

# Trees to pack (relative to HermesGo/)
SLIM_SUBTREES = (
    "runtime/python311",
    "runtime/hermes-agent",
    "runtime/hermes-webui",
    "runtime/bin",
    "home",
    "workspace",
    "logs",
    "webui-data",
    "data",
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
        dirs[:] = [d for d in dirs if d not in SKIP_DIR_NAMES]
        rel_root = os.path.relpath(root, SCRIPT_DIR).replace("\\", "/")
        if rel_root == "runtime/hermes-agent" and "tests" in dirs:
            dirs.remove("tests")
        if rel_root == "runtime/hermes-webui" and "tests" in dirs:
            dirs.remove("tests")
        for fname in files:
            if fname in SKIP_FILES:
                continue
            src = os.path.join(root, fname)
            sub = os.path.relpath(src, base).replace("\\", "/")
            rel_full = f"{rel_prefix}/{sub}".replace("//", "/") if rel_prefix else sub

            if _under_models(rel_full) or _under_ollama_runtime(rel_full) or _under_installers(rel_full):
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
        # Root launchers only
        for name in sorted(SLIM_ROOT_FILES):
            p = os.path.join(SCRIPT_DIR, name)
            if not os.path.isfile(p):
                continue
            arc = f"HermesGo/{name}"
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

        for sub in SLIM_SUBTREES:
            abs_base = os.path.join(SCRIPT_DIR, sub)
            c, s = add_tree(zf, abs_base, sub.replace("\\", "/"))
            included += c
            included_size += s

        zf.writestr(
            zipfile.ZipInfo(
                "HermesGo/app/scripts/Start-HermesGo.ps1",
                datetime.datetime.now().timetuple()[:6],
            ),
            ps1_fixed.encode("utf-8"),
        )

        slim_readme = (
            "# HermesGo slim package\n\n"
            "This archive contains portable Python, Hermes Agent, and Hermes WebUI only.\n\n"
            "Not included (use the full bundle if you need them):\n"
            "- Bundled Ollama runtime (`runtime/ollama`)\n"
            "- Pre-downloaded Ollama model blobs (`data/ollama/models`)\n"
            "- Large optional installers under `installers/`\n"
            "- Duplicate development copy of agent sources at package root\n\n"
            "Cloud API keys (e.g. DeepSeek) work as in the full package. "
            "For local Gemma/Ollama, install Ollama separately or add models under "
            "`app/data/ollama/models`.\n"
        )
        zf.writestr(
            zipfile.ZipInfo(
                "HermesGo/PACKAGE-SLIM.md",
                datetime.datetime.now().timetuple()[:6],
            ),
            slim_readme.encode("utf-8"),
        )

    zsize = os.path.getsize(ZIP_PATH)
    print(f"Building: {ZIP_NAME}")
    print(f"Files: {included}, raw ~{included_size / 1024 / 1024:.1f} MB")
    print(f"ZIP: {zsize / 1024 / 1024:.1f} MB")
    print(f"Done: {ZIP_PATH}")

    desktop = r"C:\Users\Administrator\Desktop"
    try:
        shutil.copy2(ZIP_PATH, os.path.join(desktop, ZIP_NAME))
        print(f"Desktop: {os.path.join(desktop, ZIP_NAME)}")
    except OSError as e:
        print(f"Desktop copy skipped: {e}")


if __name__ == "__main__":
    main()
