"""Sync a local test/install tree to match a green slim ZIP layout exactly."""
from __future__ import annotations

import os
import shutil
import sys
import tempfile
import zipfile

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
if SCRIPT_DIR not in sys.path:
    sys.path.insert(0, SCRIPT_DIR)

from packaging_release import PRESERVE_APP_DIRS, verify_test_package_matches_zip
from packaging_safe import assert_zip_has_no_reserved_entries

DEFAULT_TEST_PACKAGE_ROOT = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "HermesGo-slim-test-v014",
    "HermesGo",
)


def _backup_preserved(dest_root: str, tmp: str) -> dict[str, str]:
    backed: dict[str, str] = {}
    for rel in PRESERVE_APP_DIRS:
        src = os.path.join(dest_root, *rel.split("/"))
        if not os.path.isdir(src):
            continue
        bdst = os.path.join(tmp, "preserve", *rel.split("/"))
        os.makedirs(os.path.dirname(bdst), exist_ok=True)
        shutil.copytree(src, bdst, dirs_exist_ok=True)
        backed[rel] = bdst
    return backed


def _restore_preserved(dest_root: str, backed: dict[str, str]) -> None:
    for rel, bdst in backed.items():
        target = os.path.join(dest_root, *rel.split("/"))
        if os.path.isdir(target):
            shutil.rmtree(target, ignore_errors=True)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        shutil.copytree(bdst, target, dirs_exist_ok=True)


def sync_test_package_from_zip(zip_path: str, dest_root: str) -> None:
    """Replace *dest_root* with zip contents; restore preserved app state dirs."""
    zip_path = os.path.abspath(zip_path)
    dest_root = os.path.abspath(dest_root)
    if not os.path.isfile(zip_path):
        raise FileNotFoundError(zip_path)

    with tempfile.TemporaryDirectory(prefix="hg-sync-") as tmp:
        preserved = _backup_preserved(dest_root, tmp) if os.path.isdir(dest_root) else {}

        stage = os.path.join(tmp, "stage")
        with zipfile.ZipFile(zip_path) as zf:
            assert_zip_has_no_reserved_entries(zf.namelist())
            zf.extractall(stage)

        pkg = os.path.join(stage, "HermesGo")
        if not os.path.isdir(pkg):
            raise ValueError("ZIP must contain HermesGo/ at top level")

        parent = os.path.dirname(dest_root)
        os.makedirs(parent, exist_ok=True)
        if os.path.isdir(dest_root):
            shutil.rmtree(dest_root)
        shutil.copytree(pkg, dest_root)
        _restore_preserved(dest_root, preserved)

    print(f"Test package synced: {dest_root}")
    print(f"  from zip: {zip_path}")
    if preserved:
        print(f"  preserved: {', '.join(sorted(preserved))}")

    mismatches = verify_test_package_matches_zip(zip_path, dest_root)
    if mismatches:
        raise RuntimeError(
            "Test package sync verification failed:\n  - " + "\n  - ".join(mismatches)
        )
    print("Test package sync verified (key files match zip)")

    configure_mod_path = os.path.join(SCRIPT_DIR, "packaging", "configure_test_package.py")
    if os.path.isfile(configure_mod_path):
        import importlib.util

        spec = importlib.util.spec_from_file_location(
            "hermesgo_configure_test_package", configure_mod_path
        )
        mod = importlib.util.module_from_spec(spec)
        assert spec and spec.loader
        spec.loader.exec_module(mod)
        mod.configure_test_package(dest_root)


def _read_sync_dest_file(path: str) -> str | None:
    if not path or not os.path.isfile(path):
        return None
    try:
        with open(path, encoding="utf-8") as handle:
            text = (handle.read() or "").strip()
        return text or None
    except OSError:
        return None


def resolve_test_package_root() -> str:
    override = os.environ.get("HERMESGO_TEST_PACKAGE_ROOT", "").strip()
    if override:
        return override

    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    for candidate in (
        os.path.join(repo_root, "sync-dest.txt"),
        os.path.join(repo_root, "HermesGo", "sync-dest.txt"),
        os.path.join(repo_root, "HermesGo", "home", "sync-dest.txt"),
        os.path.join(repo_root, "HermesGo", "app", "sync-dest.txt"),
        os.path.join(repo_root, "HermesGo", "app", "home", "sync-dest.txt"),
    ):
        picked = _read_sync_dest_file(candidate)
        if picked:
            return picked

    return DEFAULT_TEST_PACKAGE_ROOT


def find_latest_slim_zip(dist_dir: str) -> str | None:
    if not os.path.isdir(dist_dir):
        return None
    candidates = [
        os.path.join(dist_dir, name)
        for name in os.listdir(dist_dir)
        if name.endswith(".zip") and "green-3ui-slim" in name.lower()
    ]
    if not candidates:
        return None
    return max(candidates, key=os.path.getmtime)


def main() -> int:
    import argparse

    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    dist_dir = os.path.join(repo_root, "dist")

    parser = argparse.ArgumentParser(description="Sync test package tree from slim ZIP")
    parser.add_argument("--zip", help="Path to HermesGo-*-green-3ui-slim.zip")
    parser.add_argument("--dest", default=resolve_test_package_root(), help="Test package root")
    args = parser.parse_args()

    zip_path = args.zip
    if not zip_path:
        zip_path = find_latest_slim_zip(dist_dir)
    if not zip_path:
        print(f"ERROR: no slim zip in {dist_dir}; build first or pass --zip")
        return 2

    sync_test_package_from_zip(zip_path, args.dest)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
