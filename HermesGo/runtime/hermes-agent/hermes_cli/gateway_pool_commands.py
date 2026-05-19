"""CLI helpers for the unified gateway pool manifest."""

from __future__ import annotations

import json
import os
from argparse import Namespace
from dataclasses import asdict
from typing import List

import yaml

from agent.gateway_pool import (
    GatewayBackend,
    GatewayPoolManifest,
    get_gateway_pool_litellm_path,
    get_gateway_pool_manifest_path,
    load_gateway_pool_manifest,
    save_gateway_pool_manifest,
    write_litellm_config,
)

_FREE_BOOTSTRAP_PROVIDER_ORDER = [
    "copilot",
    "deepseek",
    "alibaba",
    "zai",
    "kimi-coding",
    "arcee",
    "minimax",
    "xai",
    "ai-gateway",
]


def _parse_tags(raw: str) -> List[str]:
    return [part.strip() for part in raw.split(",") if part.strip()]


def _print_payload(payload, output_format: str) -> None:
    if output_format == "json":
        print(json.dumps(payload, ensure_ascii=False, indent=2))
        return
    print(yaml.safe_dump(payload, allow_unicode=True, sort_keys=False))


def _cmd_show(args: Namespace) -> None:
    manifest = load_gateway_pool_manifest()
    payload = asdict(manifest)
    payload["manifest_path"] = str(get_gateway_pool_manifest_path())
    payload["litellm_config_path"] = str(get_gateway_pool_litellm_path())
    _print_payload(payload, args.format)


def _cmd_init(args: Namespace) -> None:
    manifest = load_gateway_pool_manifest()
    manifest.frontend_base_url = args.frontend_base_url
    manifest.master_key = args.master_key or ""
    manifest.master_key_env = args.master_key_env
    manifest.metadata["managed_by"] = "hermes"
    manifest.metadata["frontend_key_mode"] = "single"
    path = save_gateway_pool_manifest(manifest)
    print(f"Gateway pool manifest written: {path}")


def _cmd_add_backend(args: Namespace) -> None:
    manifest = load_gateway_pool_manifest()
    backend = GatewayBackend(
        id=args.backend_id,
        model_name=args.model_name,
        upstream_model=args.upstream_model,
        provider=args.provider,
        api_key_env=args.api_key_env or "",
        base_url=args.base_url or "",
        enabled=not getattr(args, "disabled", False),
        weight=args.weight,
        rpm=args.rpm,
        tpm=args.tpm,
        tags=_parse_tags(args.tags or ""),
    )

    replaced = False
    updated_backends = []
    for existing in manifest.backends:
        if existing.id == backend.id:
            updated_backends.append(backend)
            replaced = True
        else:
            updated_backends.append(existing)
    if not replaced:
        updated_backends.append(backend)
    manifest.backends = updated_backends

    path = save_gateway_pool_manifest(manifest)
    action = "updated" if replaced else "added"
    print(f"Gateway backend {action}: {backend.id}")
    print(f"Manifest: {path}")


def _cmd_write_litellm(args: Namespace) -> None:
    manifest = load_gateway_pool_manifest()
    path = write_litellm_config(manifest)
    print(f"LiteLLM config written: {path}")


def _pick_provider_key_env(provider_id: str, env_values: dict[str, str]) -> str:
    from hermes_cli.auth import PROVIDER_REGISTRY

    cfg = PROVIDER_REGISTRY.get(provider_id)
    if not cfg:
        return ""
    for env_name in cfg.api_key_env_vars:
        if env_values.get(env_name) or os.getenv(env_name):
            return str(env_name)
    return ""


def _cmd_bootstrap_free(args: Namespace) -> None:
    from hermes_cli.auth import PROVIDER_REGISTRY
    from hermes_cli.config import load_env
    from hermes_cli.models import get_default_model_for_provider

    env_values = load_env()
    alias = str(getattr(args, "model_alias", "") or "free")
    provider_csv = str(getattr(args, "providers", "") or "")
    ordered_candidates = _FREE_BOOTSTRAP_PROVIDER_ORDER
    if provider_csv.strip():
        ordered_candidates = [part.strip() for part in provider_csv.split(",") if part.strip()]

    manifest = load_gateway_pool_manifest()
    manifest.frontend_base_url = args.frontend_base_url
    manifest.master_key = args.master_key or ""
    manifest.master_key_env = args.master_key_env
    manifest.metadata["managed_by"] = "hermes"
    manifest.metadata["bootstrap_profile"] = "free-first"
    manifest.metadata["frontend_key_mode"] = "single"
    manifest.metadata["model_alias"] = alias

    selected_backends: list[GatewayBackend] = []
    missing_providers: list[str] = []
    for provider_id in ordered_candidates:
        cfg = PROVIDER_REGISTRY.get(provider_id)
        if not cfg:
            continue
        env_name = _pick_provider_key_env(provider_id, env_values)
        if not env_name:
            missing_providers.append(provider_id)
            continue
        upstream_model = get_default_model_for_provider(provider_id) or "gpt-4.1-mini"
        selected_backends.append(
            GatewayBackend(
                id=f"{provider_id}-free",
                model_name=alias,
                upstream_model=upstream_model,
                provider=provider_id,
                api_key_env=env_name,
                base_url=cfg.inference_base_url or "",
                enabled=True,
                weight=1,
                tags=["free-first", provider_id],
            )
        )

    manifest.backends = selected_backends
    manifest.metadata["missing_providers"] = missing_providers
    manifest_path = save_gateway_pool_manifest(manifest)
    print(f"Gateway pool free profile written: {manifest_path}")
    print(f"Backends enabled: {len(selected_backends)}")
    if selected_backends:
        print("Enabled providers: " + ", ".join(backend.provider for backend in selected_backends))
    else:
        print("No free-first providers detected from current env/.env keys.")
    if missing_providers:
        print("Missing keys/providers: " + ", ".join(missing_providers))
        print("Tip: configure keys in Dashboard > Keys or run `hermes auth add <provider>`.")

    if getattr(args, "write_litellm", False):
        litellm_path = write_litellm_config(manifest)
        print(f"LiteLLM config written: {litellm_path}")


def gateway_pool_command(args: Namespace) -> None:
    action = getattr(args, "gateway_pool_action", None) or "show"
    if action == "show":
        _cmd_show(args)
        return
    if action == "init":
        _cmd_init(args)
        return
    if action == "add-backend":
        _cmd_add_backend(args)
        return
    if action == "write-litellm":
        _cmd_write_litellm(args)
        return
    if action == "bootstrap-free":
        _cmd_bootstrap_free(args)
        return
    raise SystemExit(f"Unsupported gateway-pool action: {action}")
