"""HermesGo slim: bundled optional-skills paths (runtime + build)."""
from __future__ import annotations

import os
import shutil
from pathlib import Path

SLIM_BUNDLED_OPTIONAL_SKILL_PATHS: tuple[str, ...] = (
    "research/duckduckgo-search",
    "research/domain-intel",
    "research/scrapling",
    "devops/docker-management",
    "communication/one-three-one-rule",
)

SLIM_OPTIONAL_SKILLS_EXTERNAL_DIR_NAMES: tuple[str, ...] = (
    "research",
    "devops",
    "communication",
)

SLIM_PYTHON_WEB_EXTRAS: tuple[str, ...] = ("ddgs",)

# VS Code / Zed ACP editor integration (agent-client-protocol PyPI package).
SLIM_PYTHON_ACP_EXTRAS: tuple[str, ...] = ("agent-client-protocol>=0.9.0,<1.0",)


def bundled_skills_source_root(hermes_go_dir: str | Path) -> Path:
    return Path(hermes_go_dir).resolve() / "optional-skills"


def stage_bundled_optional_skills(
    hermes_go_dir: str | Path,
    dest_app_root: str | Path,
) -> tuple[int, list[str]]:
    """Copy selected optional-skills into ``{app}/optional-skills/``."""
    src_root = bundled_skills_source_root(hermes_go_dir)
    dest_root = Path(dest_app_root).resolve() / "optional-skills"
    copied = 0
    missing: list[str] = []

    for rel in SLIM_BUNDLED_OPTIONAL_SKILL_PATHS:
        src = src_root / rel.replace("/", os.sep)
        dst = dest_root / rel.replace("/", os.sep)
        if not (src / "SKILL.md").is_file():
            missing.append(rel)
            continue
        if dst.exists():
            shutil.rmtree(dst, ignore_errors=True)
        shutil.copytree(src, dst)
        copied += 1

    return copied, missing
