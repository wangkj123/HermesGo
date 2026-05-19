"""Gateway pool manifest helpers for one-front-key / many-backend runtimes.

This module intentionally targets API/provider/local-model pools, not
ChatGPT/Codex login-state rotation.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any, Dict, List, Optional

import yaml

from hermes_constants import get_hermes_home
from utils import atomic_yaml_write


def get_gateway_pool_dir() -> Path:
    return get_hermes_home() / "gateway-pool"


def get_gateway_pool_manifest_path() -> Path:
    return get_gateway_pool_dir() / "pool.yaml"


def get_gateway_pool_litellm_path() -> Path:
    return get_gateway_pool_dir() / "litellm.config.yaml"


@dataclass
class GatewayBackend:
    id: str
    model_name: str
    upstream_model: str
    provider: str = "openai"
    api_key_env: str = ""
    base_url: str = ""
    enabled: bool = True
    weight: int = 1
    rpm: Optional[int] = None
    tpm: Optional[int] = None
    tags: List[str] = field(default_factory=list)

    @classmethod
    def from_dict(cls, payload: Dict[str, Any]) -> "GatewayBackend":
        return cls(
            id=str(payload["id"]),
            model_name=str(payload["model_name"]),
            upstream_model=str(payload["upstream_model"]),
            provider=str(payload.get("provider") or "openai"),
            api_key_env=str(payload.get("api_key_env") or ""),
            base_url=str(payload.get("base_url") or ""),
            enabled=bool(payload.get("enabled", True)),
            weight=int(payload.get("weight", 1) or 1),
            rpm=int(payload["rpm"]) if payload.get("rpm") is not None else None,
            tpm=int(payload["tpm"]) if payload.get("tpm") is not None else None,
            tags=list(payload.get("tags") or []),
        )


@dataclass
class GatewayPoolManifest:
    frontend_base_url: str = "http://127.0.0.1:4000/v1"
    master_key: str = ""
    master_key_env: str = "HERMES_GATEWAY_MASTER_KEY"
    backends: List[GatewayBackend] = field(default_factory=list)
    metadata: Dict[str, Any] = field(default_factory=dict)

    @classmethod
    def from_dict(cls, payload: Dict[str, Any]) -> "GatewayPoolManifest":
        return cls(
            frontend_base_url=str(payload.get("frontend_base_url") or "http://127.0.0.1:4000/v1"),
            master_key=str(payload.get("master_key") or ""),
            master_key_env=str(payload.get("master_key_env") or "HERMES_GATEWAY_MASTER_KEY"),
            backends=[
                GatewayBackend.from_dict(item)
                for item in (payload.get("backends") or [])
                if isinstance(item, dict)
            ],
            metadata=dict(payload.get("metadata") or {}),
        )


def save_gateway_pool_manifest(manifest: GatewayPoolManifest) -> Path:
    path = get_gateway_pool_manifest_path()
    payload = asdict(manifest)
    atomic_yaml_write(path, payload, sort_keys=False)
    return path


def load_gateway_pool_manifest() -> GatewayPoolManifest:
    path = get_gateway_pool_manifest_path()
    try:
        raw = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    except (FileNotFoundError, OSError, UnicodeDecodeError, yaml.YAMLError):
        return GatewayPoolManifest()
    return GatewayPoolManifest.from_dict(raw)


def _render_master_key(manifest: GatewayPoolManifest) -> str:
    if manifest.master_key:
        return manifest.master_key
    if manifest.master_key_env:
        return f"os.environ/{manifest.master_key_env}"
    return "change-me"


def render_litellm_config(manifest: GatewayPoolManifest) -> Dict[str, Any]:
    model_list: List[Dict[str, Any]] = []
    for backend in manifest.backends:
        if not backend.enabled:
            continue

        litellm_params: Dict[str, Any] = {
            "model": backend.upstream_model,
        }
        if backend.base_url:
            litellm_params["api_base"] = backend.base_url
        if backend.api_key_env:
            litellm_params["api_key"] = f"os.environ/{backend.api_key_env}"
        if backend.rpm is not None:
            litellm_params["rpm"] = backend.rpm
        if backend.tpm is not None:
            litellm_params["tpm"] = backend.tpm

        model_list.append(
            {
                "model_name": backend.model_name,
                "litellm_params": litellm_params,
                "model_info": {
                    "id": backend.id,
                    "provider": backend.provider,
                    "weight": backend.weight,
                    "tags": list(backend.tags),
                },
            }
        )

    return {
        "model_list": model_list,
        "litellm_settings": {
            "master_key": _render_master_key(manifest),
        },
    }


def write_litellm_config(manifest: Optional[GatewayPoolManifest] = None) -> Path:
    effective = manifest or load_gateway_pool_manifest()
    path = get_gateway_pool_litellm_path()
    payload = render_litellm_config(effective)
    atomic_yaml_write(path, payload, sort_keys=False)
    return path
