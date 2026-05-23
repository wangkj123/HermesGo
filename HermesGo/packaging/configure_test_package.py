"""Apply DeepSeek API key + provider route to HermesGo slim test tree (app/home)."""
from __future__ import annotations

import os
import re
from pathlib import Path

DEFAULT_KEY_FILE = Path(__file__).resolve().parent / "test-deepseek.key"
ENV_KEY = "HERMESGO_DEEPSEEK_API_KEY"

DEEPSEEK_BASE = "https://api.deepseek.com/v1"
DEEPSEEK_MODEL = "deepseek-v4-flash"


def _read_key() -> str:
    key = os.environ.get(ENV_KEY, "").strip()
    if key:
        return key
    if DEFAULT_KEY_FILE.is_file():
        text = DEFAULT_KEY_FILE.read_text(encoding="utf-8").strip()
        for line in text.splitlines():
            line = line.strip()
            if line and not line.startswith("#"):
                return line
    return ""


def _write_env(home: Path, key: str) -> None:
    env_path = home / ".env"
    lines: list[str] = []
    if env_path.is_file():
        lines = env_path.read_text(encoding="utf-8", errors="replace").splitlines()
    out: list[str] = []
    seen_key = False
    seen_base = False
    for raw in lines:
        if re.match(r"^\s*DEEPSEEK_API_KEY\s*=", raw):
            out.append(f"DEEPSEEK_API_KEY={key}")
            seen_key = True
            continue
        if re.match(r"^\s*DEEPSEEK_BASE_URL\s*=", raw):
            out.append(f"DEEPSEEK_BASE_URL={DEEPSEEK_BASE}")
            seen_base = True
            continue
        out.append(raw)
    if not seen_key:
        out.append(f"DEEPSEEK_API_KEY={key}")
    if not seen_base:
        out.append(f"DEEPSEEK_BASE_URL={DEEPSEEK_BASE}")
    env_path.write_text("\n".join(out).rstrip() + "\n", encoding="utf-8")


def _write_config(home: Path) -> None:
    cfg_path = home / "config.yaml"
    template = home / "config.yaml.slim-default"
    if not cfg_path.is_file() and template.is_file():
        cfg_path.write_text(template.read_text(encoding="utf-8"), encoding="utf-8")
    if not cfg_path.is_file():
        cfg_path.write_text(
            f'model:\n  provider: "deepseek"\n  default: "{DEEPSEEK_MODEL}"\n'
            f'  base_url: "{DEEPSEEK_BASE}"\n',
            encoding="utf-8",
        )
        return
    text = cfg_path.read_text(encoding="utf-8")
    text = re.sub(
        r'(\bprovider:\s*)["\']?[^"\'\n]+["\']?',
        r'\1"deepseek"',
        text,
        count=1,
    )
    text = re.sub(
        r'(\bdefault:\s*)["\']?[^"\'\n]+["\']?',
        rf'\1"{DEEPSEEK_MODEL}"',
        text,
        count=1,
    )
    text = re.sub(
        r'(\bbase_url:\s*)["\']?[^"\'\n]+["\']?',
        rf'\1"{DEEPSEEK_BASE}"',
        text,
        count=1,
    )
    cfg_path.write_text(text, encoding="utf-8")


def configure_test_package(dest_root: str | Path) -> bool:
    """Write DeepSeek credentials under ``{dest}/app/home`` or ``{dest}/home``."""
    root = Path(dest_root).resolve()
    home = root / "app" / "home"
    if not home.is_dir():
        home = root / "home"
    if not home.is_dir():
        print(f"WARN: no home dir under {root}")
        return False

    key = _read_key()
    if not key:
        print(
            f"WARN: no DeepSeek key ({ENV_KEY} or {DEFAULT_KEY_FILE.name}); skipped test configure"
        )
        return False

    home.mkdir(parents=True, exist_ok=True)
    _write_env(home, key)
    _write_config(home)
    print(f"Configured test package DeepSeek: {home}")
    return True


def main() -> int:
    import argparse

    from packaging_sync import resolve_test_package_root

    parser = argparse.ArgumentParser(description="Configure slim test tree DeepSeek key")
    parser.add_argument("--dest", default=resolve_test_package_root())
    args = parser.parse_args()
    return 0 if configure_test_package(args.dest) else 1


if __name__ == "__main__":
    raise SystemExit(main())
