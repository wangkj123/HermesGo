import json
from argparse import Namespace

import yaml

from hermes_cli.gateway_pool_commands import gateway_pool_command


def test_gateway_pool_init_add_backend_and_show_json(tmp_path, monkeypatch, capsys):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path / "hermes"))

    gateway_pool_command(
        Namespace(
            gateway_pool_action="init",
            frontend_base_url="http://127.0.0.1:4000/v1",
            master_key="",
            master_key_env="HERMES_GATEWAY_MASTER_KEY",
        )
    )
    gateway_pool_command(
        Namespace(
            gateway_pool_action="add-backend",
            backend_id="local-01",
            model_name="local",
            upstream_model="ollama/qwen2.5-coder:14b",
            provider="ollama",
            api_key_env="",
            base_url="http://127.0.0.1:11434",
            weight=1,
            rpm=None,
            tpm=None,
            tags="local,coder",
            disabled=False,
        )
    )
    gateway_pool_command(
        Namespace(
            gateway_pool_action="show",
            format="json",
        )
    )

    output = capsys.readouterr().out
    json_start = output.find("{")
    assert json_start >= 0
    payload = json.loads(output[json_start:])
    assert payload["frontend_base_url"] == "http://127.0.0.1:4000/v1"
    assert payload["backends"][0]["id"] == "local-01"
    assert payload["backends"][0]["tags"] == ["local", "coder"]


def test_gateway_pool_write_litellm_creates_config_file(tmp_path, monkeypatch):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path / "hermes"))

    gateway_pool_command(
        Namespace(
            gateway_pool_action="init",
            frontend_base_url="http://127.0.0.1:4000/v1",
            master_key="",
            master_key_env="HERMES_GATEWAY_MASTER_KEY",
        )
    )
    gateway_pool_command(
        Namespace(
            gateway_pool_action="add-backend",
            backend_id="strong-01",
            model_name="strong",
            upstream_model="openrouter/openai/gpt-5.4",
            provider="openrouter",
            api_key_env="OPENROUTER_API_KEY",
            base_url="",
            weight=1,
            rpm=30,
            tpm=60000,
            tags="strong",
            disabled=False,
        )
    )
    gateway_pool_command(Namespace(gateway_pool_action="write-litellm"))

    content = (tmp_path / "hermes" / "gateway-pool" / "litellm.config.yaml").read_text(encoding="utf-8")
    payload = yaml.safe_load(content)
    assert payload["model_list"][0]["model_name"] == "strong"
    assert payload["litellm_settings"]["master_key"] == "os.environ/HERMES_GATEWAY_MASTER_KEY"


def test_gateway_pool_bootstrap_free_uses_existing_keys(tmp_path, monkeypatch):
    hermes_home = tmp_path / "hermes"
    monkeypatch.setenv("HERMES_HOME", str(hermes_home))
    (hermes_home / ".env").parent.mkdir(parents=True, exist_ok=True)
    (hermes_home / ".env").write_text(
        "DEEPSEEK_API_KEY=sk-deepseek-test\n",
        encoding="utf-8",
    )

    gateway_pool_command(
        Namespace(
            gateway_pool_action="bootstrap-free",
            frontend_base_url="http://127.0.0.1:4000/v1",
            master_key="",
            master_key_env="HERMES_GATEWAY_MASTER_KEY",
            model_alias="free",
            providers="deepseek,alibaba",
            write_litellm=False,
        )
    )

    pool_yaml = (hermes_home / "gateway-pool" / "pool.yaml").read_text(encoding="utf-8")
    payload = yaml.safe_load(pool_yaml)
    assert payload["metadata"]["bootstrap_profile"] == "free-first"
    assert payload["backends"][0]["provider"] == "deepseek"
    assert payload["backends"][0]["api_key_env"] == "DEEPSEEK_API_KEY"
    assert payload["backends"][0]["model_name"] == "free"


def test_gateway_pool_bootstrap_free_with_no_keys_creates_empty_backends(tmp_path, monkeypatch):
    hermes_home = tmp_path / "hermes"
    monkeypatch.setenv("HERMES_HOME", str(hermes_home))

    gateway_pool_command(
        Namespace(
            gateway_pool_action="bootstrap-free",
            frontend_base_url="http://127.0.0.1:4000/v1",
            master_key="",
            master_key_env="HERMES_GATEWAY_MASTER_KEY",
            model_alias="free",
            providers="deepseek,alibaba",
            write_litellm=False,
        )
    )

    pool_yaml = (hermes_home / "gateway-pool" / "pool.yaml").read_text(encoding="utf-8")
    payload = yaml.safe_load(pool_yaml)
    assert payload["backends"] == []
    assert payload["metadata"]["missing_providers"] == ["deepseek", "alibaba"]
