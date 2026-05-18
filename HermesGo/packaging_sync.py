"""Sync a local test/install tree to match a green slim ZIP layout exactly."""
from __future__ import annotations

import os
import shutil
import tempfile
import zipfile

from packaging_safe import assert_zip_has_no_reserved_entries

# User state under app/ — kept across sync (same as bootstrap ApplyUpdate preserve).
PRESERVE_APP_DIRS = (
    "app/home",
    "app/data",
    "app/logs",
    "app/workspace",
    "app/webui-data",
)

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


def resolve_test_package_root() -> str:
    override = os.environ.get("HERMESGO_TEST_PACKAGE_ROOT", "").strip()
    return override or DEFAULT_TEST_PACKAGE_ROOT


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
