"""Guardrails for HermesGo portable ZIP packaging on Windows."""
from __future__ import annotations

_RESERVED_BASE_NAMES = frozenset(
    {"con", "prn", "aux", "nul"}
    | {f"com{i}" for i in range(1, 10)}
    | {f"lpt{i}" for i in range(1, 10)}
)


def is_windows_reserved_name(name: str) -> bool:
    """True if *name* is a Windows reserved device name (with or without extension)."""
    if not name:
        return False
    stem = name.split(".", 1)[0].lower()
    return stem in _RESERVED_BASE_NAMES


def should_skip_pack_path(relative_path: str) -> bool:
    """True if any path component is a reserved Windows device name."""
    for part in relative_path.replace("\\", "/").split("/"):
        if not part or part in {".", ".."}:
            continue
        if is_windows_reserved_name(part):
            return True
    return False


def assert_zip_has_no_reserved_entries(namelist: list[str]) -> None:
    """Raise ValueError if any ZIP member ends with a reserved device file name."""
    bad = [n for n in namelist if should_skip_pack_path(n)]
    if bad:
        sample = ", ".join(bad[:5])
        raise ValueError(f"ZIP contains Windows reserved paths: {sample}")
