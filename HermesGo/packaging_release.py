"""Shared slim release metadata, version bump, dist cleanup, sync verification."""
from __future__ import annotations

import hashlib
import os
import re
import zipfile

# Single source of truth for slim green builds (keep in sync with GitHub release tag).
SLIM_VERSION = "0.14.6"
RELEASE_SUFFIX = "green-3ui-slim"
RELEASE_TAG = f"v{SLIM_VERSION}-{RELEASE_SUFFIX}"

# Relative to package content root (app/ in green layout).
PRESERVE_CONTENT_DIRS = (
    "home",
    "data",
    "logs",
    "workspace",
    "webui-data",
)

PRESERVE_APP_DIRS = tuple(f"app/{name}" for name in PRESERVE_CONTENT_DIRS)

RUNTIME_VERSION_FILE = os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    "runtime",
    "hermes-agent",
    "hermes_cli",
    "__init__.py",
)

SYNC_VERIFY_ZIP_PATHS = (
    "HermesGo/app/scripts/Start-HermesGo.ps1",
    "HermesGo/app/runtime/hermes-agent/hermes_cli/__init__.py",
    "HermesGo/app/scripts/check_dashboard_gateway.py",
    "HermesGo/app/runtime/hermes-agent/agent/async_utils.py",
)

SYNC_VERIFY_DEST_PATHS = (
    "app/scripts/Start-HermesGo.ps1",
    "app/runtime/hermes-agent/hermes_cli/__init__.py",
    "app/scripts/check_dashboard_gateway.py",
    "app/runtime/hermes-agent/agent/async_utils.py",
)


def ensure_runtime_version(version: str = SLIM_VERSION, init_path: str = RUNTIME_VERSION_FILE) -> None:
    """Rewrite __version__ in hermes_cli/__init__.py if it does not match *version*."""
    init_path = os.path.abspath(init_path)
    if not os.path.isfile(init_path):
        raise FileNotFoundError(init_path)

    text = open(init_path, encoding="utf-8").read()
    pattern = re.compile(r'(__version__\s*=\s*["\'])([^"\']+)(["\'])', re.MULTILINE)
    match = pattern.search(text)
    if not match:
        raise ValueError(f"__version__ not found in {init_path}")

    current = match.group(2)
    if current == version:
        print(f"Runtime version already {version}")
        return

    updated = pattern.sub(rf"\g<1>{version}\g<3>", text, count=1)
    with open(init_path, "w", encoding="utf-8", newline="\n") as f:
        f.write(updated)
    print(f"Bumped runtime __version__: {current} -> {version}")


def read_runtime_version(init_path: str = RUNTIME_VERSION_FILE) -> str:
    text = open(init_path, encoding="utf-8").read()
    match = re.search(r'__version__\s*=\s*["\']([^"\']+)["\']', text)
    if not match:
        raise ValueError(f"__version__ not found in {init_path}")
    return match.group(1)


def _sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def verify_test_package_matches_zip(zip_path: str, dest_root: str) -> list[str]:
    """Return list of mismatch descriptions (empty if OK)."""
    zip_path = os.path.abspath(zip_path)
    dest_root = os.path.abspath(dest_root)
    mismatches: list[str] = []

    with zipfile.ZipFile(zip_path) as zf:
        for zrel, drel in zip(SYNC_VERIFY_ZIP_PATHS, SYNC_VERIFY_DEST_PATHS):
            dest_file = os.path.join(dest_root, *drel.split("/"))
            try:
                zhash = _sha256_bytes(zf.read(zrel))
            except KeyError:
                mismatches.append(f"zip missing: {zrel}")
                continue
            if not os.path.isfile(dest_file):
                mismatches.append(f"dest missing: {drel}")
                continue
            dhash = _sha256_file(dest_file)
            if zhash != dhash:
                mismatches.append(f"{drel}: zip {zhash[:16]} != dest {dhash[:16]}")

    init_dest = os.path.join(
        dest_root, "app", "runtime", "hermes-agent", "hermes_cli", "__init__.py"
    )
    if os.path.isfile(init_dest):
        try:
            runtime_ver = read_runtime_version(init_dest)
            if runtime_ver != SLIM_VERSION:
                mismatches.append(
                    f"runtime __version__={runtime_ver!r} expected {SLIM_VERSION!r}"
                )
        except ValueError as exc:
            mismatches.append(str(exc))

    return mismatches


def prune_old_slim_zips(dist_dir: str, keep_zip_path: str) -> int:
    """Delete older green-3ui-slim zips in *dist_dir*; keep *keep_zip_path* only."""
    dist_dir = os.path.abspath(dist_dir)
    keep_zip_path = os.path.abspath(keep_zip_path)
    removed = 0
    if not os.path.isdir(dist_dir):
        return removed

    for name in os.listdir(dist_dir):
        if not name.lower().endswith(".zip"):
            continue
        if "green-3ui-slim" not in name.lower():
            continue
        path = os.path.join(dist_dir, name)
        if os.path.abspath(path) == keep_zip_path:
            continue
        try:
            os.remove(path)
            print(f"Removed old slim zip: {name}")
            removed += 1
        except OSError as exc:
            print(f"WARN: could not remove {name}: {exc}")
    return removed
