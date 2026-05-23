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


def _ensure_portable_optional_skills_tree() -> bool:
    """Copy bundled skills into app/optional-skills when missing (dev trees, pre-rebuild installs)."""
    try:
        from hermes_constants import get_portable_app_root
        from hermes_cli.portable_bundled_skills import stage_bundled_optional_skills
    except Exception:
        return False

    app_root = get_portable_app_root()
    if app_root is None:
        return False

    marker = app_root / "optional-skills" / "research" / "duckduckgo-search" / "SKILL.md"
    if marker.is_file():
        return False

    for candidate in (app_root.parent.parent, app_root.parent, app_root):
        src = candidate / "optional-skills"
        if not src.is_dir():
            continue
        stage_bundled_optional_skills(candidate, app_root)
        return True
    return False


def _merge_portable_skills_external_dirs() -> bool:
    """Ensure config.yaml lists bundled app/optional-skills when present."""
    try:
        from hermes_constants import get_portable_app_root
        from hermes_cli.config import get_config_path, load_config, save_config
        from hermes_cli.portable_bundled_skills import SLIM_OPTIONAL_SKILLS_EXTERNAL_DIR_NAMES
    except Exception:
        return False

    app_root = get_portable_app_root()
    if app_root is None:
        return False

    opt_root = app_root / "optional-skills"
    if not opt_root.is_dir():
        return False

    wanted: list[str] = []
    for name in SLIM_OPTIONAL_SKILLS_EXTERNAL_DIR_NAMES:
        if (opt_root / name).is_dir():
            wanted.append(f"${{HERMES_PORTABLE_APP_ROOT}}/optional-skills/{name}")

    if not wanted:
        return False

    cfg = load_config()
    skills_cfg = cfg.get("skills")
    if not isinstance(skills_cfg, dict):
        skills_cfg = {}
        cfg["skills"] = skills_cfg

    raw_dirs = skills_cfg.get("external_dirs")
    if raw_dirs is None:
        existing: list[str] = []
    elif isinstance(raw_dirs, str):
        existing = [raw_dirs]
    elif isinstance(raw_dirs, list):
        existing = [str(x).strip() for x in raw_dirs if str(x).strip()]
    else:
        existing = []

    changed = False
    for entry in wanted:
        if entry not in existing:
            existing.append(entry)
            changed = True

    if not changed:
        return False

    skills_cfg["external_dirs"] = existing
    save_config(cfg)
    return True


def _portable_pip_install_missing(packages: tuple[str, ...]) -> bool:
    """Install PyPI packages into bundled python311 when not already present."""
    try:
        from hermes_constants import get_portable_app_root
    except Exception:
        return False

    app_root = get_portable_app_root()
    if app_root is None:
        return False

    py = app_root / "runtime" / "python311" / "python.exe"
    if not py.is_file():
        return False

    import subprocess

    index = os.environ.get(
        "HERMESGO_PYPI_INDEX",
        "https://pypi.tuna.tsinghua.edu.cn/simple",
    )
    offline = os.environ.get("HERMESGO_NO_PIP_DOWNLOAD", "").strip().lower() in (
        "1",
        "true",
        "yes",
    )
    installed_any = False
    for spec in packages:
        name = str(spec).split("==")[0].split("[")[0].strip()
        name = name.split(">=")[0].split("<")[0].split("!=")[0].strip()
        if not name:
            continue
        probe = subprocess.run(
            [str(py), "-m", "pip", "show", name],
            capture_output=True,
            text=True,
        )
        if probe.returncode == 0:
            continue
        if offline:
            continue
        subprocess.run(
            [str(py), "-m", "pip", "install", spec, "-i", index, "-q"],
            check=False,
        )
        installed_any = True
    return installed_any


def ensure_portable_web_search_deps() -> bool:
    """Install ddgs into bundled Python when duckduckgo-search skill is shipped."""
    try:
        from hermes_cli.portable_bundled_skills import SLIM_PYTHON_WEB_EXTRAS
    except Exception:
        return False
    return _portable_pip_install_missing(SLIM_PYTHON_WEB_EXTRAS)


def ensure_portable_web_search_installed() -> bool:
    """Ensure web_search works offline: ddgs in python311 + config web.backend=duckduckgo."""
    ok_deps = ensure_portable_web_search_deps()
    ok_cfg = _ensure_portable_web_backend_config()
    if not _ddgs_importable():
        return False
    try:
        import sys
        from pathlib import Path
        from hermes_constants import get_portable_app_root

        app_root = get_portable_app_root()
        if app_root is None:
            return False
        agent = Path(app_root) / "runtime" / "hermes-agent"
        if str(agent) not in sys.path:
            sys.path.insert(0, str(agent))
        from tools.web_tools import check_web_api_key, web_search_tool  # noqa: F401

        if not check_web_api_key():
            return False
    except Exception:
        return False
    return ok_deps or ok_cfg or True


def _ensure_portable_web_backend_config() -> bool:
    """Point slim green installs at bundled ddgs when no paid web API keys are set."""
    if not _ddgs_importable():
        return False
    try:
        from hermes_cli.config import load_config, save_config
    except Exception:
        return False

    cfg = load_config()
    web_cfg = cfg.get("web")
    if not isinstance(web_cfg, dict):
        web_cfg = {}

    for key in ("FIRECRAWL_API_KEY", "TAVILY_API_KEY", "PARALLEL_API_KEY", "EXA_API_KEY"):
        if _read_env_file_key(key):
            return False

    backend = str(web_cfg.get("backend") or "").strip().lower()
    if backend in ("firecrawl", "tavily", "parallel", "exa"):
        return False
    if backend == "duckduckgo":
        return False

    web_cfg["backend"] = "duckduckgo"
    cfg["web"] = web_cfg
    save_config(cfg)
    return True


def _ddgs_importable() -> bool:
    try:
        from hermes_constants import get_portable_app_root
    except Exception:
        return False
    app_root = get_portable_app_root()
    if app_root is None:
        return False
    py = app_root / "runtime" / "python311" / "python.exe"
    if not py.is_file():
        return False
    import subprocess

    probe = subprocess.run(
        [str(py), "-c", "from ddgs import DDGS"],
        capture_output=True,
        text=True,
    )
    return probe.returncode == 0


def ensure_portable_acp_deps() -> bool:
    """Install agent-client-protocol for ``hermes acp`` (VS Code / Zed editor integration)."""
    try:
        from hermes_cli.portable_bundled_skills import SLIM_PYTHON_ACP_EXTRAS
    except Exception:
        return False
    return _portable_pip_install_missing(SLIM_PYTHON_ACP_EXTRAS)


def ensure_portable_exe_ready() -> dict[str, str]:
    """One-shot portable setup for HermesGo.exe / HermesGo.bat (config, env, Windows-only)."""
    from hermes_constants import ensure_hermes_green_windows_env, ensure_portable_hermes_home_env

    home = ensure_portable_hermes_home_env()
    ensure_hermes_green_windows_env()
    summary: dict[str, str] = {"hermes_home": str(home)}

    if _ensure_portable_optional_skills_tree():
        summary["optional_skills"] = "staged"
    if _merge_portable_skills_external_dirs():
        summary["skills"] = "external_dirs"
    if ensure_portable_web_search_installed():
        summary["web_search"] = "ddgs+web_search"
    elif ensure_portable_web_search_deps():
        summary["web_deps"] = "ddgs"
    if ensure_portable_acp_deps():
        summary["acp_deps"] = "acp"
    if _ensure_portable_web_backend_config():
        summary["web_backend"] = "duckduckgo"

    if ensure_portable_deepseek_route():
        summary["model_route"] = "deepseek"
    if ensure_deepseek_config_if_key():
        summary["deepseek_key"] = "applied"
    elif ensure_codex_config_if_authed():
        summary["model_route"] = "openai-codex"

    return summary


def ensure_portable_deepseek_route() -> bool:
    """HermesGo slim portable: always use DeepSeek (never auto-switch to Codex)."""
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
