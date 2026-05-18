from agent.smart_model_routing import choose_cheap_model_route


_BASE_CONFIG = {
    "enabled": True,
    "cheap_model": {
        "provider": "openrouter",
        "model": "google/gemini-2.5-flash",
    },
}


def test_returns_none_when_disabled():
    cfg = {**_BASE_CONFIG, "enabled": False}
    assert choose_cheap_model_route("what time is it in tokyo?", cfg) is None


def test_routes_short_simple_prompt():
    result = choose_cheap_model_route("what time is it in tokyo?", _BASE_CONFIG)
    assert result is not None
    assert result["provider"] == "openrouter"
    assert result["model"] == "google/gemini-2.5-flash"
    assert result["routing_reason"] == "simple_turn"


def test_skips_long_prompt():
    prompt = "please summarize this carefully " * 20
    assert choose_cheap_model_route(prompt, _BASE_CONFIG) is None


def test_skips_code_like_prompt():
    prompt = "debug this traceback: ```python\nraise ValueError('bad')\n```"
    assert choose_cheap_model_route(prompt, _BASE_CONFIG) is None


def test_skips_tool_heavy_prompt_keywords():
    prompt = "implement a patch for this docker error"
    assert choose_cheap_model_route(prompt, _BASE_CONFIG) is None


def test_resolve_turn_route_falls_back_to_primary_when_route_runtime_cannot_be_resolved(monkeypatch):
    from agent.smart_model_routing import resolve_turn_route

    monkeypatch.setattr(
        "hermes_cli.runtime_provider.resolve_runtime_provider",
        lambda **kwargs: (_ for _ in ()).throw(RuntimeError("bad route")),
    )
    result = resolve_turn_route(
        "what time is it in tokyo?",
        _BASE_CONFIG,
        {
            "model": "anthropic/claude-sonnet-4",
            "provider": "openrouter",
            "base_url": "https://openrouter.ai/api/v1",
            "api_mode": "chat_completions",
            "api_key": "sk-primary",
        },
    )
    assert result["model"] == "anthropic/claude-sonnet-4"
    assert result["runtime"]["provider"] == "openrouter"
    assert result["label"] is None


def test_routes_medium_prompt_when_medium_model_configured():
    from agent.smart_model_routing import choose_medium_model_route

    cfg = {
        "enabled": True,
        "medium_model": {
            "provider": "custom",
            "model": "litellm-medium",
            "base_url": "http://127.0.0.1:4000/v1",
        },
    }
    result = choose_medium_model_route("帮我整理一下这个需求，列出三段摘要和一个行动清单。", cfg)
    assert result is not None
    assert result["provider"] == "custom"
    assert result["model"] == "litellm-medium"
    assert result["routing_reason"] == "medium_turn"


def test_medium_route_inherits_gateway_defaults():
    from agent.smart_model_routing import choose_medium_model_route

    cfg = {
        "enabled": True,
        "gateway": {
            "provider": "custom",
            "base_url": "http://127.0.0.1:4000/v1",
            "api_key_env": "LITELLM_API_KEY",
        },
        "medium_model": {
            "model": "litellm-medium",
        },
    }
    result = choose_medium_model_route("请整理这份会议纪要，拆成目标、风险和下一步。", cfg)
    assert result is not None
    assert result["provider"] == "custom"
    assert result["base_url"] == "http://127.0.0.1:4000/v1"
    assert result["api_key_env"] == "LITELLM_API_KEY"


def test_medium_route_skips_complex_prompt():
    from agent.smart_model_routing import choose_medium_model_route

    cfg = {
        "enabled": True,
        "medium_model": {
            "provider": "custom",
            "model": "litellm-medium",
            "base_url": "http://127.0.0.1:4000/v1",
        },
    }
    prompt = "debug this traceback and implement a patch for the failing docker build"
    assert choose_medium_model_route(prompt, cfg) is None
