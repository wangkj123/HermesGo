"""Tests for Windows reserved-name packaging guardrails."""
from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from packaging_safe import (  # noqa: E402
    assert_zip_has_no_reserved_entries,
    is_windows_reserved_name,
    should_skip_pack_path,
)


def test_reserved_names():
    assert is_windows_reserved_name("nul")
    assert is_windows_reserved_name("NUL")
    assert is_windows_reserved_name("com1")
    assert is_windows_reserved_name("LPT9.txt")
    assert not is_windows_reserved_name("null-loader")
    assert not is_windows_reserved_name("README.md")


def test_should_skip_pack_path():
    assert should_skip_pack_path("HermesGo/app/nul")
    assert should_skip_pack_path(r"HermesGo\app\con")
    assert not should_skip_pack_path("HermesGo/app/README.md")


def test_assert_zip_has_no_reserved_entries():
    assert_zip_has_no_reserved_entries(["HermesGo/HermesGo.bat"])
    try:
        assert_zip_has_no_reserved_entries(["HermesGo/nul"])
    except ValueError as exc:
        assert "reserved" in str(exc).lower()
    else:
        raise AssertionError("expected ValueError for reserved zip entry")
