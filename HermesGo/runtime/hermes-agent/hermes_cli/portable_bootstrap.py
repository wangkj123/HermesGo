"""Portable HermesGo first-run helpers (auth import → config alignment)."""
from __future__ import annotations

import json
import os
from pathlib import Path


def _read_env_file_key(key: str) -> str:
    try:
        from hermes_cli.config import get_hermes_home
    except Exception:
        return ""
    env_path = Path(get_hermes_home()) / ".env"
    if not env_path.is_file():
        return ""
    want = key.strip()
    for raw in env_path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        name, value = line.split("=", 1)
        if name.strip() == want:
            return value.strip().strip('"').strip("'")
    return ""


def _deepseek_api_key() -> str:
    for source in (
        os.environ.get("DEEPSEEK_API_KEY", ""),
        os.environ.get("HERMESGO_DEEPSEEK_API_KEY", ""),
        _read_env_file_key("DEEPSEEK_API_KEY"),
    ):
        if str(source or "").strip():
            return str(source).strip()
    return ""


def _codex_auth_exhausted() -> bool:
    try:
        from hermes_cli.config import get_hermes_home
    except Exception:
        return False
    auth_path = Path(get_hermes_home()) / "auth.json"
    if not auth_path.is_file():
        return False
    try:
        data = json.loads(auth_path.read_text(encoding="utf-8"))
    except Exception:
        return False
    pool = data.get("credential_pool") or {}
    entries = pool.get("openai-codex") or []
    if not isinstance(entries, list):
        return False
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        if str(entry.get("last_status") or "").strip().lower() == "exhausted":
            return True
        msg = str(entry.get("last_error_message") or "").lower()
        if "usage limit" in msg or entry.get("last_error_code") == 429:
            return True
    return False


def _looks_like_codex_model(model_id: str, default_models: list[str]) -> bool:
    model = (model_id or "").strip().lower()
    if not model:
        return False
    if model in {item.lower() for item in default_models}:
        return True
    return "codex" in model or model.startswith("gpt-5.")


def ensure_deepseek_config_if_key() -> bool:
    """When DEEPSEEK_API_KEY is available, prefer DeepSeek in config.yaml."""
    if not _deepseek_api_key():
        return False
    try:
        from hermes_cli.auth import _update_config_for_provider
        from hermes_cli.config import load_config
    except Exception:
        return False

    cfg = load_config()
    model_cfg = cfg.get("model")
    if not isinstance(model_cfg, dict):
        model_cfg = {}

    provider = str(model_cfg.get("provider") or "").strip()
    default = str(model_cfg.get("default") or model_cfg.get("name") or "").strip()
    base_url = str(model_cfg.get("base_url") or "").strip().rstrip("/")
    target_base = "https://api.deepseek.com/v1"
    target_model = default if default.startswith("deepseek") else "deepseek-v4-flash"

    if (
        provider == "deepseek"
        and default.startswith("deepseek")
        and base_url.rstrip("/") == target_base
    ):
        return False

    _update_config_for_provider(
        "deepseek",
        target_base,
        default_model=target_model,
    )
    return True


def ensure_codex_config_if_authed() -> bool:
    """If Codex OAuth is logged in but config still uses the slim DeepSeek template, switch to Codex."""
    if _deepseek_api_key() or _codex_auth_exhausted():
        return False
    try:
        from hermes_cli.auth import (
            DEFAULT_CODEX_BASE_URL,
            _update_config_for_provider,
            get_codex_auth_status,
        )
        from hermes_cli.codex_models import DEFAULT_CODEX_MODELS
        from hermes_cli.config import load_config
    except Exception:
        return False

    if not get_codex_auth_status().get("logged_in"):
        return False

    cfg = load_config()
    model_cfg = cfg.get("model")
    if not isinstance(model_cfg, dict):
        return False

    provider = str(model_cfg.get("provider") or "").strip()
    default = str(model_cfg.get("default") or model_cfg.get("name") or "").strip()
    base_url = str(model_cfg.get("base_url") or "").strip().rstrip("/")

    model_id = DEFAULT_CODEX_MODELS[0] if DEFAULT_CODEX_MODELS else "gpt-5.4-mini"

    if provider == "openai-codex":
        if _looks_like_codex_model(default, DEFAULT_CODEX_MODELS) and base_url == DEFAULT_CODEX_BASE_URL:
            return False
        _update_config_for_provider(
            "openai-codex",
            DEFAULT_CODEX_BASE_URL,
            default_model=model_id,
        )
        return True

    # Only auto-align when the user still has the untouched slim-pack default.
    if provider == "deepseek" and default and default != "deepseek-v4-flash":
        return False
    if provider and provider != "deepseek":
        return False

    _update_config_for_provider(
        "openai-codex",
        DEFAULT_CODEX_BASE_URL,
        default_model=model_id,
    )
    return True
