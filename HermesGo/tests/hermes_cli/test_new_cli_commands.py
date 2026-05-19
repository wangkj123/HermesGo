import sys


def test_gateway_pool_subcommand_routes_to_handler(monkeypatch):
    import hermes_cli.main as main_mod

    captured = {}

    def fake_cmd_gateway_pool(args):
        captured["command"] = args.command
        captured["action"] = args.gateway_pool_action
        captured["backend_id"] = args.backend_id

    monkeypatch.setattr(main_mod, "cmd_gateway_pool", fake_cmd_gateway_pool)
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "hermes",
            "gateway-pool",
            "add-backend",
            "--id",
            "local-01",
            "--model-name",
            "local",
            "--upstream-model",
            "ollama/qwen2.5-coder:14b",
        ],
    )

    main_mod.main()

    assert captured == {
        "command": "gateway-pool",
        "action": "add-backend",
        "backend_id": "local-01",
    }


def test_gateway_pool_bootstrap_free_routes_to_handler(monkeypatch):
    import hermes_cli.main as main_mod

    captured = {}

    def fake_cmd_gateway_pool(args):
        captured["command"] = args.command
        captured["action"] = args.gateway_pool_action
        captured["model_alias"] = args.model_alias
        captured["write_litellm"] = args.write_litellm

    monkeypatch.setattr(main_mod, "cmd_gateway_pool", fake_cmd_gateway_pool)
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "hermes",
            "gateway-pool",
            "bootstrap-free",
            "--model-alias",
            "starter",
            "--write-litellm",
        ],
    )

    main_mod.main()

    assert captured == {
        "command": "gateway-pool",
        "action": "bootstrap-free",
        "model_alias": "starter",
        "write_litellm": True,
    }


def test_selfext_subcommand_routes_to_handler(monkeypatch):
    import hermes_cli.main as main_mod

    captured = {}

    def fake_cmd_selfext(args):
        captured["command"] = args.command
        captured["action"] = args.selfext_action
        captured["goal"] = args.goal
        captured["route_tier"] = args.route_tier

    monkeypatch.setattr(main_mod, "cmd_selfext", fake_cmd_selfext)
    monkeypatch.setattr(
        sys,
        "argv",
        ["hermes", "selfext", "start", "让", "Hermes", "继续", "--route-tier", "medium"],
    )

    main_mod.main()

    assert captured == {
        "command": "selfext",
        "action": "start",
        "goal": ["让", "Hermes", "继续"],
        "route_tier": "medium",
    }


def test_selfext_prepare_workspace_subcommand_routes_to_handler(monkeypatch):
    import hermes_cli.main as main_mod

    captured = {}

    def fake_cmd_selfext(args):
        captured["command"] = args.command
        captured["action"] = args.selfext_action
        captured["goal"] = args.goal
        captured["workspace_dir"] = args.workspace_dir

    monkeypatch.setattr(main_mod, "cmd_selfext", fake_cmd_selfext)
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "hermes",
            "selfext",
            "prepare-workspace",
            "让",
            "HermesGo",
            "接管",
            "--workspace-dir",
            "workspaces/hermesgo",
        ],
    )

    main_mod.main()

    assert captured == {
        "command": "selfext",
        "action": "prepare-workspace",
        "goal": ["让", "HermesGo", "接管"],
        "workspace_dir": "workspaces/hermesgo",
    }
