from agent.run_registry import (
    CheckpointRecord,
    RunRecord,
    StageRecord,
    UnitRecord,
    ensure_run_layout,
    find_latest_checkpoint,
    append_run_intervention,
    get_run_dir,
    list_checkpoint_records,
    list_run_records,
    list_stage_records,
    list_unit_records,
    load_checkpoint,
    load_run_record,
    load_stage_record,
    load_unit_record,
    update_run_status,
    write_checkpoint,
    write_run_record,
    write_stage_record,
    write_unit_record,
)


def test_run_layout_and_records(tmp_path, monkeypatch):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path / "hermes"))

    run = RunRecord(run_id="run-001", goal="实现内生账号池", profile_name="default", status="running", metadata={"route_tier": "strong"})
    stage = StageRecord(run_id="run-001", stage_id="stage-01", name="design", status="running", metadata={"owner": "architect"})
    unit = UnitRecord(run_id="run-001", stage_id="stage-01", unit_id="u1", name="write-files", status="checkpointed", metadata={"gateway_model_name": "strong"})

    ensure_run_layout(run.run_id)
    write_run_record(run)
    write_stage_record(stage)
    write_unit_record(unit)

    run_dir = get_run_dir("run-001")
    assert (run_dir / "run.json").exists()
    assert (run_dir / "stages" / "stage-01.json").exists()
    assert (run_dir / "units" / "stage-01__u1.json").exists()

    assert load_run_record("run-001").goal == "实现内生账号池"
    assert load_stage_record("run-001", "stage-01").name == "design"
    assert load_unit_record("run-001", "stage-01", "u1").status == "checkpointed"
    assert load_run_record("run-001").metadata["route_tier"] == "strong"
    assert load_stage_record("run-001", "stage-01").metadata["owner"] == "architect"
    assert load_unit_record("run-001", "stage-01", "u1").metadata["gateway_model_name"] == "strong"


def test_latest_checkpoint_selected_by_created_at(tmp_path, monkeypatch):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path / "hermes"))

    write_checkpoint(
        CheckpointRecord(
            run_id="run-002",
            stage_id="stage-01",
            unit_id="u1",
            profile_name="default",
            status="verified",
            output_summary="first",
            created_at="2026-04-23T10:00:00+00:00",
        )
    )
    write_checkpoint(
        CheckpointRecord(
            run_id="run-002",
            stage_id="stage-01",
            unit_id="u2",
            profile_name="default",
            status="verified",
            output_summary="second",
            created_at="2026-04-23T10:05:00+00:00",
        )
    )

    latest = find_latest_checkpoint("run-002")

    assert latest is not None
    assert latest.unit_id == "u2"
    assert latest.output_summary == "second"
    assert load_checkpoint("run-002", "stage-01", "u1").output_summary == "first"


def test_run_board_lists_and_control_events(tmp_path, monkeypatch):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path / "hermes"))

    write_run_record(
        RunRecord(
            run_id="run-board-001",
            goal="让 Hermes 自展任务板支持人工介入",
            profile_name="default",
            status="running",
            metadata={
                "kind": "self_extension",
                "run_type": "selfext_objective",
                "validation_scenario": "自有软件注册系统只作为验收样例",
            },
        )
    )
    write_stage_record(
        StageRecord(
            run_id="run-board-001",
            stage_id="analyze",
            name="analyze",
            status="running",
            metadata={"owner": "architect"},
        )
    )
    write_unit_record(
        UnitRecord(
            run_id="run-board-001",
            stage_id="analyze",
            unit_id="u1",
            name="split-task",
            status="checkpointed",
        )
    )
    write_checkpoint(
        CheckpointRecord(
            run_id="run-board-001",
            stage_id="analyze",
            unit_id="u1",
            profile_name="default",
            status="checkpointed",
            output_summary="waiting for user approval",
        )
    )

    paused = update_run_status("run-board-001", "paused", note="人工暂停", actor="dashboard")
    intervened = append_run_intervention("run-board-001", "业务场景只作为验收，不作为 SelfExt 本体", actor="dashboard")

    assert paused.status == "paused"
    assert list_run_records()[0].run_id == "run-board-001"
    assert list_stage_records("run-board-001")[0].metadata["owner"] == "architect"
    assert list_unit_records("run-board-001")[0].name == "split-task"
    assert list_checkpoint_records("run-board-001")[0].output_summary == "waiting for user approval"
    assert intervened.metadata["control_events"][0]["note"] == "人工暂停"
    assert intervened.metadata["interventions"][0]["message"] == "业务场景只作为验收，不作为 SelfExt 本体"
