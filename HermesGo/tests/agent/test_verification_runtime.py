import sys
from pathlib import Path

from agent.run_registry import CheckpointRecord, write_checkpoint
from agent.verification_runtime import (
    VerificationCheck,
    load_verification_registry,
    reread_failed_verification,
    run_verification_check,
    save_verification_registry,
)


def test_save_and_load_verification_registry(tmp_path, monkeypatch):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path / "hermes"))

    path = save_verification_registry([
        VerificationCheck(id="verify-unit", kind="unit", command=[sys.executable, "-c", "print('ok')"]),
    ])

    assert path.exists()
    checks = load_verification_registry()
    assert len(checks) == 1
    assert checks[0].id == "verify-unit"


def test_run_verification_check_writes_logs_and_result(tmp_path, monkeypatch):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path / "hermes"))

    result = run_verification_check(
        "run-verify-1",
        VerificationCheck(id="verify-pass", kind="unit", command=[sys.executable, "-c", "print('pass')"]),
        metadata={"route_tier": "local"},
    )

    assert result.status == "pass"
    assert Path(result.stdout_log).exists()
    assert "pass" in Path(result.stdout_log).read_text(encoding="utf-8")
    assert result.metadata["route_tier"] == "local"


def test_reread_failed_verification_includes_latest_checkpoint(tmp_path, monkeypatch):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path / "hermes"))

    target_file = tmp_path / "broken.txt"
    target_file.write_text("broken-output", encoding="utf-8")

    write_checkpoint(
        CheckpointRecord(
            run_id="run-verify-2",
            stage_id="stage-01",
            unit_id="u1",
            profile_name="default",
            status="checkpointed",
            output_summary="checkpoint-before-failure",
            created_at="2026-04-23T10:10:00+00:00",
        )
    )

    result = run_verification_check(
        "run-verify-2",
        VerificationCheck(
            id="verify-fail",
            kind="scenario",
            command=[sys.executable, "-c", "import sys; print('bad', file=sys.stderr); sys.exit(2)"],
        ),
    )

    reread = reread_failed_verification(
        "run-verify-2",
        "verify-fail",
        related_files=[str(target_file)],
    )

    assert result.status == "fail"
    assert "bad" in reread["stderr_tail"]
    assert reread["latest_checkpoint"]["output_summary"] == "checkpoint-before-failure"
    assert reread["related_files"][0]["tail"] == "broken-output"
