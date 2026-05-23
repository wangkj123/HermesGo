"""Build-time re-export of slim bundled skills (see hermes_cli/portable_bundled_skills.py)."""
from __future__ import annotations

import sys
from pathlib import Path

_AGENT = Path(__file__).resolve().parents[1] / "runtime" / "hermes-agent"
if str(_AGENT) not in sys.path:
    sys.path.insert(0, str(_AGENT))

from hermes_cli.portable_bundled_skills import (  # noqa: E402
    SLIM_BUNDLED_OPTIONAL_SKILL_PATHS,
    SLIM_OPTIONAL_SKILLS_EXTERNAL_DIR_NAMES,
    SLIM_PYTHON_WEB_EXTRAS,
    stage_bundled_optional_skills,
)

__all__ = [
    "SLIM_BUNDLED_OPTIONAL_SKILL_PATHS",
    "SLIM_OPTIONAL_SKILLS_EXTERNAL_DIR_NAMES",
    "SLIM_PYTHON_WEB_EXTRAS",
    "stage_bundled_optional_skills",
]
