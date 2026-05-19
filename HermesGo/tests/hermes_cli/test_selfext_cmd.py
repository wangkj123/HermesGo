import json
from argparse import Namespace
from pathlib import Path

from hermes_cli.selfext_commands import selfext_command


def test_selfext_start_uses_active_profile_when_profile_not_provided(tmp_path, monkeypatch, capsys):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path / "hermes"))

    selfext_command(
        Namespace(
            selfext_action="start",
            goal=["让", "Hermes", "自己接管自展"],
            profile_name=None,
            route_tier="medium",
            gateway_model_name=None,
            run_id="selfext-cli-001",
        )
    )

    payload = json.loads(capsys.readouterr().out)
    assert payload["run_id"] == "selfext-cli-001"
    assert payload["route_tier"] == "medium"
    assert payload["gateway_model_name"] == "medium"


def test_selfext_show_prints_run_and_latest_checkpoint(tmp_path, monkeypatch, capsys):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path / "hermes"))

    selfext_command(
        Namespace(
            selfext_action="start",
            goal=["准备", "自展任务"],
            profile_name="default",
            route_tier="strong",
            gateway_model_name="strong",
            run_id="selfext-cli-002",
        )
    )
    capsys.readouterr()

    selfext_command(
        Namespace(
            selfext_action="show",
            run_id="selfext-cli-002",
        )
    )

    payload = json.loads(capsys.readouterr().out)
    assert payload["run"]["run_id"] == "selfext-cli-002"
    assert payload["run"]["metadata"]["kind"] == "self_extension"
    assert payload["latest_checkpoint"]["output_summary"] == "self-extension run bootstrapped"


def test_selfext_prepare_workspace_prints_workspace_payload(tmp_path, monkeypatch, capsys):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path / "hermes"))

    source_root = tmp_path / "source"
    workspace_dir = tmp_path / "isolated" / "hermesgo"
    (source_root / "HermesGo").mkdir(parents=True)
    (source_root / ".cursorrules").write_text("rules", encoding="utf-8")
    (source_root / "AGENTS.md").write_text("agents", encoding="utf-8")
    (source_root / "HermesGo" / "README.md").write_text("subtree", encoding="utf-8")

    selfext_command(
        Namespace(
            selfext_action="prepare-workspace",
            goal=["准备", "HermesGo", "接管目录"],
            profile_name="default",
            route_tier="local",
            gateway_model_name=None,
            source_root=str(source_root),
            workspace_dir=str(workspace_dir),
            run_id="selfext-cli-prepare-001",
        )
    )

    payload = json.loads(capsys.readouterr().out)
    assert payload["run_id"] == "selfext-cli-prepare-001"
    assert payload["route_tier"] == "local"
    assert Path(payload["workspace_root"]).is_dir()
    assert Path(payload["hermesgo_dir"]).joinpath("README.md").read_text(encoding="utf-8") == "subtree"
    assert Path(payload["start_guide_file"]).exists()
    assert Path(payload["launcher_file"]).exists()
    assert Path(payload["manifest_file"]).name == "workspace-manifest.json"
