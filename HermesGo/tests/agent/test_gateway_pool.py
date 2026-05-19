from agent.gateway_pool import (
    GatewayBackend,
    GatewayPoolManifest,
    load_gateway_pool_manifest,
    render_litellm_config,
    save_gateway_pool_manifest,
    write_litellm_config,
)


def test_gateway_pool_manifest_roundtrip(tmp_path, monkeypatch):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path / "hermes"))

    manifest = GatewayPoolManifest(
        frontend_base_url="http://127.0.0.1:4000/v1",
        master_key_env="HERMES_GATEWAY_MASTER_KEY",
        backends=[
            GatewayBackend(
                id="local-01",
                model_name="local",
                upstream_model="ollama/qwen2.5-coder:14b",
                provider="ollama",
                base_url="http://127.0.0.1:11434",
            ),
            GatewayBackend(
                id="strong-01",
                model_name="strong",
                upstream_model="openrouter/anthropic/claude-sonnet-4.5",
                provider="openrouter",
                api_key_env="OPENROUTER_API_KEY",
            ),
        ],
        metadata={"owner": "hermes"},
    )

    path = save_gateway_pool_manifest(manifest)
    assert path.exists()

    loaded = load_gateway_pool_manifest()
    assert loaded.master_key_env == "HERMES_GATEWAY_MASTER_KEY"
    assert len(loaded.backends) == 2
    assert loaded.backends[0].model_name == "local"
    assert loaded.backends[1].api_key_env == "OPENROUTER_API_KEY"


def test_render_litellm_config_uses_single_front_key_and_multiple_backends():
    manifest = GatewayPoolManifest(
        master_key_env="HERMES_GATEWAY_MASTER_KEY",
        backends=[
            GatewayBackend(
                id="medium-a",
                model_name="medium",
                upstream_model="openrouter/google/gemini-2.5-flash",
                provider="openrouter",
                api_key_env="OPENROUTER_KEY_A",
            ),
            GatewayBackend(
                id="medium-b",
                model_name="medium",
                upstream_model="openrouter/google/gemini-2.5-flash",
                provider="openrouter",
                api_key_env="OPENROUTER_KEY_B",
            ),
        ],
    )

    payload = render_litellm_config(manifest)
    assert payload["litellm_settings"]["master_key"] == "os.environ/HERMES_GATEWAY_MASTER_KEY"
    assert len(payload["model_list"]) == 2
    assert payload["model_list"][0]["model_name"] == "medium"
    assert payload["model_list"][1]["litellm_params"]["api_key"] == "os.environ/OPENROUTER_KEY_B"


def test_write_litellm_config_writes_yaml(tmp_path, monkeypatch):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path / "hermes"))
    manifest = GatewayPoolManifest(
        backends=[
            GatewayBackend(
                id="strong-01",
                model_name="strong",
                upstream_model="openrouter/openai/gpt-5.4",
                provider="openrouter",
                api_key_env="OPENROUTER_API_KEY",
            )
        ]
    )
    path = write_litellm_config(manifest)
    assert path.exists()
    content = path.read_text(encoding="utf-8")
    assert "model_list:" in content
    assert "strong" in content
