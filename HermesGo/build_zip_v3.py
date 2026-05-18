"""Build portable ZIP from this HermesGo tree (HermesGo/ + HermesGo/app/* layout)."""
import zipfile, os, datetime, shutil, io, sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SCRIPT_DIR)
from packaging_safe import assert_zip_has_no_reserved_entries, is_windows_reserved_name, should_skip_pack_path
SRC = SCRIPT_DIR
# Keep output outside SRC so os.walk does not try to read the zip being written
OUT_DIR = os.path.join(os.path.dirname(SCRIPT_DIR), "dist")
DT = datetime.datetime.now().strftime("%Y.%m.%d-%H%M")
zip_name = f"HermesGo-{DT}-DeepSeek-v13-WebUI-portable.zip"
zip_path = os.path.join(OUT_DIR, zip_name)

print(f"Building: {zip_name}")
os.makedirs(OUT_DIR, exist_ok=True)

# Never exclude names that also exist under site-packages (e.g. "sessions", "codex").
EXCLUDE_DIRS = {'__pycache__', 'node_modules', '.git'}
EXCLUDE_FILES = {
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
# Dev-only artifacts at repo root (do not ship inside portable zip)
EXCLUDE_TOP_NAMES = {'create_hermes_go', 'exports', 'workspaces'}

# Canonical launcher from repo (always matches source control)
ps1_repo = os.path.join(SCRIPT_DIR, "Start-HermesGo.ps1")
with open(ps1_repo, 'r', encoding='utf-8') as f:
    ps1_fixed = f.read()

# Also fix home/logs/webui-data/workspace paths for ZIP layout
# These are derived from $root, so if root = HermesGo/app/, paths work
# But if PS1 is at root and root = HermesGo/, we need to adjust
# Actually the fallback above handles this - if runtime is in app/, root becomes app/

included = 0
included_size = 0

with zipfile.ZipFile(zip_path, 'w', zipfile.ZIP_DEFLATED, compresslevel=5) as zf:
    for root, dirs, files in os.walk(SRC):
        dirs[:] = [
            d for d in dirs
            if d not in EXCLUDE_DIRS and not is_windows_reserved_name(d)
        ]
        # Skip parallel repo trees under HermesGo/
        if root == SRC:
            dirs[:] = [d for d in dirs if d not in EXCLUDE_TOP_NAMES]
        
        for fname in files:
            src_path = os.path.join(root, fname)
            rel = os.path.relpath(src_path, SRC)
            fsize = os.path.getsize(src_path)
            
            if fname in EXCLUDE_FILES or is_windows_reserved_name(fname):
                continue
            parent = os.path.basename(os.path.dirname(src_path))
            if parent in EXCLUDE_DIRS:
                continue
            
            top = rel.split(os.sep)[0]

            # Only the repo-root launcher is canonical; skip stray copies under subdirs
            if fname == "Start-HermesGo.ps1" and rel.replace("\\", "/") != "Start-HermesGo.ps1":
                continue

            # Special handling for Start-HermesGo.ps1: ship repo-canonical text once
            if fname == "Start-HermesGo.ps1":
                content = ps1_fixed.encode("utf-8")
                arcname = "HermesGo/Start-HermesGo.ps1"
            elif top in ("runtime", "home", "logs", "workspace", "webui-data"):
                arcname = f"HermesGo/app/{rel}"
            else:
                arcname = f"HermesGo/{rel}"

            if should_skip_pack_path(arcname):
                continue

            if fname == "Start-HermesGo.ps1":
                zf.writestr(
                    zipfile.ZipInfo(arcname, datetime.datetime.now().timetuple()[:6]),
                    content,
                )
            else:
                zf.write(src_path, arcname)
            
            included += 1
            included_size += fsize
    
    # Also put a copy of the fixed PS1 in app/scripts/ for the BAT to call
    zf.writestr(zipfile.ZipInfo("HermesGo/app/scripts/Start-HermesGo.ps1",
        datetime.datetime.now().timetuple()[:6]), ps1_fixed.encode('utf-8'))

with zipfile.ZipFile(zip_path, "r") as zf:
    assert_zip_has_no_reserved_entries(zf.namelist())

zip_size = os.path.getsize(zip_path)

print(f"Files: {included}, {included_size/1024/1024:.1f} MB")
print(f"ZIP: {zip_size/1024/1024:.1f} MB")

# Copy to Desktop
desktop = r"C:\Users\Administrator\Desktop"
try:
    # Remove old versions
    for f in os.listdir(desktop):
        if f.startswith("HermesGo-2026.05.10") and f.endswith(".zip"):
            os.remove(os.path.join(desktop, f))
    shutil.copy2(zip_path, os.path.join(desktop, zip_name))
    print(f"Desktop: {os.path.join(desktop, zip_name)}")
except Exception as e:
    print(f"Desktop: {e}")

print(f"\nDone! {zip_path}")
