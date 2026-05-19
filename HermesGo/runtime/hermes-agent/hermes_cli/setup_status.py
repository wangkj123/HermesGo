"""Shared setup / provider readiness snapshot for Dashboard and WebUI."""
from __future__ import annotations

import os
from typing import Any, Dict

_OAUTH_PROVIDERS = (
    "openai-codex",
    "copilot",
    "copilot-acp",
    "qwen-oauth",
    "nous",
    "anthropic",
)


def _model_fields(cfg: dict) -> tuple[str, str, str]:
    model_cfg = cfg.get("model")
    if isinstance(model_cfg, dict):
        return (
            str(model_cfg.get("provider") or "").strip(),
            str(model_cfg.get("default") or model_cfg.get("name") or "").strip(),
            str(model_cfg.get("base_url") or "").strip(),
        )
    if isinstance(model_cfg, str):
        return ("", model_cfg.strip(), "")
    return ("", "", "")


def _oauth_logged_in(provider_id: str) -> Dict[str, Any]:
    try:
        from hermes_cli.auth import get_auth_status

        status = get_auth_status(provider_id)
        if isinstance(status, dict):
            return {
                "logged_in": bool(status.get("logged_in")),
                "error": status.get("error"),
            }
    except Exception as exc:
        return {"logged_in": False, "error": str(exc)}
    return {"logged_in": False, "error": None}


def get_setup_status() -> Dict[str, Any]:
    """Return human-readable setup state for the active Hermes home."""
    from hermes_cli.config import get_hermes_home, load_config
    from hermes_cli.main import _has_any_provider_configured

    cfg = load_config()
    provider, model, base_url = _model_fields(cfg)
    home = str(get_hermes_home())

    auth: Dict[str, Any] = {}
    for pid in _OAUTH_PROVIDERS:
        auth[pid] = _oauth_logged_in(pid)

    runtime_ready = False
    runtime_error = None
    if provider:
        try:
            from hermes_cli.runtime_provider import resolve_runtime_provider

            runtime = resolve_runtime_provider(requested=provider)
            has_key = bool(str(runtime.get("api_key") or "").strip())
            api_mode = str(runtime.get("api_mode") or "")
            runtime_ready = has_key or api_mode == "external_process"
            if not runtime_ready:
                runtime_error = "API key or OAuth token missing for configured provider"
        except Exception as exc:
            runtime_error = str(exc)

    configured = bool(provider and model)
    codex = auth.get("openai-codex") or {}
    codex_ok = bool(codex.get("logged_in"))

    if codex_ok and not configured:
        state = "provider_incomplete"
        message = (
            "OpenAI Codex 已登录，但尚未在 config.yaml 中选择 provider/model。"
            "请在 Dashboard「环境」页确认 OAuth 为已连接，并在模型设置中选择 openai-codex。"
        )
        message_en = (
            "OpenAI Codex is authenticated but config.yaml has no provider/model. "
            "Pick openai-codex in model settings."
        )
        return {
            "setup_state": state,
            "configured": False,
            "runtime_ready": False,
            "chat_ready": bool(_has_any_provider_configured()),
            "provider": provider or None,
            "model": model or None,
            "base_url": base_url or None,
            "hermes_home": home,
            "message": message,
            "message_en": message_en,
            "runtime_error": runtime_error,
            "auth": auth,
            "codex_connected": codex_ok,
        }

    if configured and runtime_ready:
        state = "ready"
        if provider == "openai-codex" and codex_ok:
            message = f"已配置并就绪：OpenAI Codex（{model or 'default model'}）"
            message_en = f"Ready: OpenAI Codex ({model or 'default model'})"
        else:
            message = f"已配置并就绪：{provider} / {model}"
            message_en = f"Ready: {provider} / {model}"
    elif configured and not runtime_ready:
        state = "provider_incomplete"
        if provider == "openai-codex":
            message = (
                "已选择 OpenAI Codex，但尚未登录或令牌已过期。"
                "请在下方 OAuth 区域点击 Connect，或运行：hermes auth add openai-codex"
            )
            message_en = (
                "OpenAI Codex is selected but not authenticated. "
                "Use Connect below or run: hermes auth add openai-codex"
            )
        else:
            message = (
                f"已选择 {provider}，但凭证未就绪。"
                f"{runtime_error or '请检查 API Key 或 OAuth 登录。'}"
            )
            message_en = (
                f"Provider {provider} is selected but credentials are not ready. "
                f"{runtime_error or 'Check API key or OAuth login.'}"
            )
    else:
        state = "needs_provider"
        message = "尚未配置模型提供商。请在 OAuth 登录或环境变量中配置 API Key，或运行 hermes setup"
        message_en = "No model provider configured. Connect OAuth, set API keys, or run hermes setup"

    from hermes_constants import display_hermes_home, get_portable_app_root

    portable_root = get_portable_app_root()
    return {
        "setup_state": state,
        "configured": configured,
        "runtime_ready": runtime_ready,
        "chat_ready": bool(_has_any_provider_configured()) and runtime_ready,
        "provider": provider or None,
        "model": model or None,
        "base_url": base_url or None,
        "hermes_home": home,
        "hermes_home_display": display_hermes_home(),
        "portable_app_root": str(portable_root) if portable_root else None,
        "message": message,
        "message_en": message_en,
        "runtime_error": runtime_error,
        "auth": auth,
        "codex_connected": codex_ok,
    }
