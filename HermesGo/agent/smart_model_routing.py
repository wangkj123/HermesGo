"""Helpers for optional simple/medium/strong turn routing."""

from __future__ import annotations

import os
import re
from typing import Any, Dict, Optional

from utils import is_truthy_value

_COMPLEX_KEYWORDS = {
    "debug",
    "debugging",
    "implement",
    "implementation",
    "refactor",
    "patch",
    "traceback",
    "stacktrace",
    "exception",
    "error",
    "analyze",
    "analysis",
    "investigate",
    "architecture",
    "design",
    "compare",
    "benchmark",
    "optimize",
    "optimise",
    "review",
    "terminal",
    "shell",
    "tool",
    "tools",
    "pytest",
    "test",
    "tests",
    "plan",
    "planning",
    "delegate",
    "subagent",
    "cron",
    "docker",
    "kubernetes",
}

_URL_RE = re.compile(r"https?://|www\.", re.IGNORECASE)


def _coerce_bool(value: Any, default: bool = False) -> bool:
    return is_truthy_value(value, default=default)


def _coerce_int(value: Any, default: int) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def _build_primary_result(primary: Dict[str, Any]) -> Dict[str, Any]:
    return {
        "model": primary.get("model"),
        "runtime": {
            "api_key": primary.get("api_key"),
            "base_url": primary.get("base_url"),
            "provider": primary.get("provider"),
            "api_mode": primary.get("api_mode"),
            "command": primary.get("command"),
            "args": list(primary.get("args") or []),
            "credential_pool": primary.get("credential_pool"),
        },
        "label": None,
        "signature": (
            primary.get("model"),
            primary.get("provider"),
            primary.get("base_url"),
            primary.get("api_mode"),
            primary.get("command"),
            tuple(primary.get("args") or ()),
        ),
    }


def _merged_route_config(route_config: Any, gateway_config: Any, *, reason: str) -> Optional[Dict[str, Any]]:
    if not isinstance(route_config, dict):
        return None

    model = str(route_config.get("model") or "").strip()
    if not model:
        return None

    gateway = gateway_config if isinstance(gateway_config, dict) else {}
    provider = str(route_config.get("provider") or gateway.get("provider") or "").strip().lower()
    if not provider:
        return None

    route = dict(gateway)
    route.update(route_config)
    route["provider"] = provider
    route["model"] = model
    route["routing_reason"] = reason
    return route


def _looks_strong(lowered: str, words: set[str], text: str) -> bool:
    if text.count("\n") > 1:
        return True
    if "```" in text or "`" in text:
        return True
    if _URL_RE.search(text):
        return True
    if words & _COMPLEX_KEYWORDS:
        return True
    return False


def choose_cheap_model_route(user_message: str, routing_config: Optional[Dict[str, Any]]) -> Optional[Dict[str, Any]]:
    """Return the configured cheap-model route when a message looks simple.

    Conservative by design: if the message has signs of code/tool/debugging/
    long-form work, keep the primary model.
    """
    cfg = routing_config or {}
    if not _coerce_bool(cfg.get("enabled"), False):
        return None

    text = (user_message or "").strip()
    if not text:
        return None

    max_chars = _coerce_int(cfg.get("max_simple_chars"), 160)
    max_words = _coerce_int(cfg.get("max_simple_words"), 28)

    if len(text) > max_chars:
        return None
    if len(text.split()) > max_words:
        return None

    lowered = text.lower()
    words = {token.strip(".,:;!?()[]{}\"'`") for token in lowered.split()}
    if _looks_strong(lowered, words, text):
        return None

    route = _merged_route_config(
        cfg.get("cheap_model") or cfg.get("simple_model"),
        cfg.get("gateway"),
        reason="simple_turn",
    )
    return route


def choose_medium_model_route(user_message: str, routing_config: Optional[Dict[str, Any]]) -> Optional[Dict[str, Any]]:
    """Return the configured medium-model route for moderate turns.

    This sits between the simple-turn local/cheap route and the primary model.
    Strong/code-heavy prompts still stay on the primary model.
    """
    cfg = routing_config or {}
    if not _coerce_bool(cfg.get("enabled"), False):
        return None

    text = (user_message or "").strip()
    if not text:
        return None

    route = _merged_route_config(cfg.get("medium_model"), cfg.get("gateway"), reason="medium_turn")
    if not route:
        return None

    max_chars = _coerce_int(cfg.get("max_medium_chars"), 1200)
    max_words = _coerce_int(cfg.get("max_medium_words"), 180)

    if len(text) > max_chars:
        return None
    if len(text.split()) > max_words:
        return None

    lowered = text.lower()
    words = {token.strip(".,:;!?()[]{}\"'`") for token in lowered.split()}
    if _looks_strong(lowered, words, text):
        return None

    simple_route = choose_cheap_model_route(text, cfg)
    if simple_route is not None:
        return None

    return route


def resolve_turn_route(user_message: str, routing_config: Optional[Dict[str, Any]], primary: Dict[str, Any]) -> Dict[str, Any]:
    """Resolve the effective model/runtime for one turn.

    Returns a dict with model/runtime/signature/label fields.
    """
    route = choose_cheap_model_route(user_message, routing_config)
    if not route:
        route = choose_medium_model_route(user_message, routing_config)
    if not route:
        return _build_primary_result(primary)

    from hermes_cli.runtime_provider import resolve_runtime_provider

    explicit_api_key = None
    api_key_env = str(route.get("api_key_env") or "").strip()
    if api_key_env:
        explicit_api_key = os.getenv(api_key_env) or None

    try:
        runtime = resolve_runtime_provider(
            requested=route.get("provider"),
            explicit_api_key=explicit_api_key,
            explicit_base_url=route.get("base_url"),
        )
    except Exception:
        return _build_primary_result(primary)

    routing_reason = str(route.get("routing_reason") or "routed_turn")

    return {
        "model": route.get("model"),
        "runtime": {
            "api_key": runtime.get("api_key"),
            "base_url": runtime.get("base_url"),
            "provider": runtime.get("provider"),
            "api_mode": runtime.get("api_mode"),
            "command": runtime.get("command"),
            "args": list(runtime.get("args") or []),
            "credential_pool": runtime.get("credential_pool"),
        },
        "label": f"smart route [{routing_reason}] → {route.get('model')} ({runtime.get('provider')})",
        "signature": (
            route.get("model"),
            runtime.get("provider"),
            runtime.get("base_url"),
            runtime.get("api_mode"),
            runtime.get("command"),
            tuple(runtime.get("args") or ()),
        ),
    }
