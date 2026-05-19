from pathlib import Path

from agent.run_registry import load_checkpoint, load_run_record, load_stage_record, load_unit_record
from agent.self_extension_runtime import bootstrap_self_extension_run, prepare_self_extension_workspace


def test_bootstrap_self_extension_run_creates_run_stage_unit_and_checkpoint(tmp_path, monkeypatch):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path / "hermes"))

    result = bootstrap_self_extension_run(
        goal="让 Hermes 自己接管自展任务",
        profile_name="default",
        route_tier="medium",
        gateway_model_name="medium",
        run_id="selfext-test-001",
    )

    assert result.run_id == "selfext-test-001"
    assert result.stage_ids == ["analyze", "implement", "verify", "archive"]
    assert result.route_tier == "medium"

    run = load_run_record("selfext-test-001")
    assert run is not None
    assert run.metadata["kind"] == "self_extension"
    assert run.metadata["run_type"] == "selfext_objective"
    assert run.metadata["selfext_scope"] == "hermes_self_improvement"
    assert run.metadata["route_tier"] == "medium"

    analyze = load_stage_record("selfext-test-001", "analyze")
    assert analyze is not None
    assert analyze.status == "running"
    assert analyze.metadata["owner"] == "architect"

    unit = load_unit_record("selfext-test-001", "analyze", "u1")
    assert unit is not None
    assert unit.name == "plan-self-extension"
    assert unit.metadata["gateway_model_name"] == "medium"

    checkpoint = load_checkpoint("selfext-test-001", "analyze", "u1")
    assert checkpoint is not None
    assert checkpoint.output_summary == "self-extension run bootstrapped"
    assert checkpoint.metadata["route_tier"] == "medium"


def test_prepare_self_extension_workspace_copies_context_and_hermesgo(tmp_path, monkeypatch):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path / "hermes-home"))

    source_root = tmp_path / "source"
    workspace_root = tmp_path / "workspaces" / "hermesgo-selfext"
    hermesgo_dir = source_root / "HermesGo"
    docs_dir = source_root / "docs" / "00-governance"
    rules_dir = source_root / ".cursor" / "rules"

    hermesgo_dir.mkdir(parents=True)
    docs_dir.mkdir(parents=True)
    rules_dir.mkdir(parents=True)

    (source_root / ".cursorrules").write_text("root rules", encoding="utf-8")
    (source_root / "AGENTS.md").write_text("workspace agents", encoding="utf-8")
    (source_root / ".codexrc").write_text("rules_file: .cursorrules", encoding="utf-8")
    (source_root / ".codex-system-prompt").write_text("read .cursorrules", encoding="utf-8")
    (source_root / "README.md").write_text("workspace readme", encoding="utf-8")
    (source_root / "docs" / "036-2026-04-23-HermesGo全功能控制台总体方案与任务拆分.md").parent.mkdir(parents=True, exist_ok=True)
    (source_root / "docs" / "036-2026-04-23-HermesGo全功能控制台总体方案与任务拆分.md").write_text("036", encoding="utf-8")
    (source_root / "docs" / "043-2026-04-23-HermesGo阶段划分与Hermes自展替代路径评估.md").write_text("043", encoding="utf-8")
    (source_root / "docs" / "045-2026-04-24-HermesGo自展底部第一轮实现归档.md").write_text("045", encoding="utf-8")
    (source_root / "docs" / "050-2026-04-24-HermesGo网关池命令与自展入口第一轮实现归档.md").write_text("050", encoding="utf-8")
    (source_root / "docs" / "00-governance" / "conflict-index.md").write_text("conflict", encoding="utf-8")
    (rules_dir / "selfext.mdc").write_text("extra rule", encoding="utf-8")
    (hermesgo_dir / "AGENTS.md").write_text("HermesGo local agents", encoding="utf-8")
    (hermesgo_dir / "README.md").write_text("HermesGo subtree", encoding="utf-8")

    result = prepare_self_extension_workspace(
        goal="让 HermesGo 接管自展工作区",
        source_root=source_root,
        workspace_root=workspace_root,
        profile_name="default",
        route_tier="medium",
        gateway_model_name="medium",
        run_id="selfext-workspace-001",
    )

    assert result.run_id == "selfext-workspace-001"
    assert Path(result.hermesgo_dir).is_dir()
    assert (workspace_root / ".cursorrules").read_text(encoding="utf-8") == "root rules"
    assert (workspace_root / ".cursor" / "rules" / "selfext.mdc").read_text(encoding="utf-8") == "extra rule"
    assert (workspace_root / "HermesGo" / "README.md").read_text(encoding="utf-8") == "HermesGo subtree"
    assert (workspace_root / "selfext" / "README.md").read_text(encoding="utf-8") == "workspace readme"
    assert (workspace_root / "SELFEXT.bat").exists()
    assert (workspace_root / "selfext" / "SELFEXT-WORKSPACE.md").exists()
    assert (workspace_root / "selfext" / "START-SELFEXT.md").exists()
    assert (workspace_root / "selfext" / "workspace-manifest.json").exists()
    assert (workspace_root / "selfext" / "bootstrap" / "Ensure-SelfExtWorkspace.ps1").exists()
    assert (workspace_root / "selfext" / "bootstrap" / "Run-SelfExt.ps1").exists()
    assert (workspace_root / "selfext" / "docs" / "036-2026-04-23-HermesGo全功能控制台总体方案与任务拆分.md").exists()

    run = load_run_record("selfext-workspace-001")
    checkpoint = load_checkpoint("selfext-workspace-001", "analyze", "u1")
    assert run is not None
    assert checkpoint is not None
    assert run.metadata["workspace_root"] == str(workspace_root.resolve())
    assert run.metadata["workspace_start_guide_file"] == str((workspace_root / "selfext" / "START-SELFEXT.md").resolve())
    assert run.metadata["workspace_launcher_file"] == str((workspace_root / "SELFEXT.bat").resolve())
    assert checkpoint.output_summary == "self-extension workspace prepared"


def test_prepare_self_extension_workspace_accepts_existing_selfext_layout_as_source(tmp_path, monkeypatch):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path / "hermes-home"))

    source_root = tmp_path / "existing-workspace"
    workspace_root = tmp_path / "workspaces" / "hermesgo-next"
    hermesgo_dir = source_root / "HermesGo"
    selfext_docs_dir = source_root / "selfext" / "docs" / "00-governance"

    hermesgo_dir.mkdir(parents=True)
    selfext_docs_dir.mkdir(parents=True)

    (source_root / ".cursorrules").write_text("root rules", encoding="utf-8")
    (source_root / "AGENTS.md").write_text("workspace agents", encoding="utf-8")
    (source_root / ".codexrc").write_text("rules_file: .cursorrules", encoding="utf-8")
    (source_root / ".codex-system-prompt").write_text("read .cursorrules", encoding="utf-8")
    (source_root / "selfext" / "README.md").write_text("workspace readme", encoding="utf-8")
    (source_root / "selfext" / "docs" / "036-2026-04-23-HermesGo全功能控制台总体方案与任务拆分.md").write_text("036", encoding="utf-8")
    (source_root / "selfext" / "docs" / "00-governance" / "conflict-index.md").write_text("conflict", encoding="utf-8")
    (hermesgo_dir / "README.md").write_text("HermesGo subtree", encoding="utf-8")

    result = prepare_self_extension_workspace(
        goal="让独立工作区继续自展",
        source_root=source_root,
        workspace_root=workspace_root,
        profile_name="default",
        route_tier="local",
        gateway_model_name="local",
        run_id="selfext-workspace-002",
    )

    assert result.run_id == "selfext-workspace-002"
    assert (workspace_root / "selfext" / "README.md").read_text(encoding="utf-8") == "workspace readme"
    assert (workspace_root / "selfext" / "docs" / "036-2026-04-23-HermesGo全功能控制台总体方案与任务拆分.md").read_text(encoding="utf-8") == "036"
    assert (workspace_root / "selfext" / "docs" / "00-governance" / "conflict-index.md").read_text(encoding="utf-8") == "conflict"
