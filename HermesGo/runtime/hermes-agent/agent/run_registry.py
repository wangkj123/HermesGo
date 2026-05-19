"""Structured run/stage/unit/checkpoint files for resumable execution."""

from __future__ import annotations

from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional
import json

from hermes_constants import get_hermes_home
from utils import atomic_json_write


def _utcnow_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def _read_json(path: Path) -> Dict[str, Any]:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, OSError, UnicodeDecodeError, json.JSONDecodeError):
        return {}


def get_runs_dir() -> Path:
    return get_hermes_home() / "runs"


def get_run_dir(run_id: str) -> Path:
    return get_runs_dir() / run_id


def ensure_run_layout(run_id: str) -> Path:
    run_dir = get_run_dir(run_id)
    for rel in ("stages", "units", "checkpoints", "artifacts", "logs", "verification"):
        (run_dir / rel).mkdir(parents=True, exist_ok=True)
    return run_dir


@dataclass
class RunRecord:
    run_id: str
    goal: str
    profile_name: str
    status: str = "queued"
    current_stage_id: Optional[str] = None
    current_unit_id: Optional[str] = None
    metadata: Dict[str, Any] = field(default_factory=dict)
    created_at: str = field(default_factory=_utcnow_iso)
    updated_at: str = field(default_factory=_utcnow_iso)


@dataclass
class StageRecord:
    run_id: str
    stage_id: str
    name: str
    status: str = "pending"
    metadata: Dict[str, Any] = field(default_factory=dict)
    created_at: str = field(default_factory=_utcnow_iso)
    updated_at: str = field(default_factory=_utcnow_iso)


@dataclass
class UnitRecord:
    run_id: str
    stage_id: str
    unit_id: str
    name: str
    status: str = "pending"
    artifacts: List[str] = field(default_factory=list)
    verification_status: Optional[str] = None
    next_action: Optional[str] = None
    metadata: Dict[str, Any] = field(default_factory=dict)
    created_at: str = field(default_factory=_utcnow_iso)
    updated_at: str = field(default_factory=_utcnow_iso)


@dataclass
class CheckpointRecord:
    run_id: str
    stage_id: str
    unit_id: str
    profile_name: str
    status: str
    input_summary: Optional[str] = None
    output_summary: Optional[str] = None
    artifact_paths: List[str] = field(default_factory=list)
    verification: Optional[Dict[str, Any]] = None
    next_action: Optional[str] = None
    metadata: Dict[str, Any] = field(default_factory=dict)
    created_at: str = field(default_factory=_utcnow_iso)


def _stage_path(run_id: str, stage_id: str) -> Path:
    return get_run_dir(run_id) / "stages" / f"{stage_id}.json"


def _unit_path(run_id: str, stage_id: str, unit_id: str) -> Path:
    return get_run_dir(run_id) / "units" / f"{stage_id}__{unit_id}.json"


def _checkpoint_path(run_id: str, stage_id: str, unit_id: str) -> Path:
    return get_run_dir(run_id) / "checkpoints" / f"{stage_id}__{unit_id}.json"


def write_run_record(record: RunRecord) -> Path:
    ensure_run_layout(record.run_id)
    record.updated_at = _utcnow_iso()
    path = get_run_dir(record.run_id) / "run.json"
    atomic_json_write(path, asdict(record))
    return path


def load_run_record(run_id: str) -> Optional[RunRecord]:
    payload = _read_json(get_run_dir(run_id) / "run.json")
    if not payload:
        return None
    return RunRecord(**payload)


def list_run_records(limit: int = 50) -> List[RunRecord]:
    runs_dir = get_runs_dir()
    if not runs_dir.is_dir():
        return []

    records: List[RunRecord] = []
    for path in runs_dir.glob("*/run.json"):
        payload = _read_json(path)
        if not payload:
            continue
        try:
            records.append(RunRecord(**payload))
        except TypeError:
            continue

    records.sort(key=lambda record: record.updated_at, reverse=True)
    return records[:limit]


def _append_metadata_event(record: RunRecord, key: str, event: Dict[str, Any]) -> None:
    events = record.metadata.get(key)
    if not isinstance(events, list):
        events = []
    events.append({"created_at": _utcnow_iso(), **event})
    record.metadata[key] = events


def update_run_status(
    run_id: str,
    status: str,
    *,
    note: Optional[str] = None,
    actor: str = "dashboard",
) -> RunRecord:
    record = load_run_record(run_id)
    if record is None:
        raise FileNotFoundError(f"Run not found: {run_id}")

    record.status = status
    event: Dict[str, Any] = {"actor": actor, "status": status}
    if note:
        event["note"] = note
    _append_metadata_event(record, "control_events", event)
    write_run_record(record)
    return record


def append_run_intervention(
    run_id: str,
    message: str,
    *,
    actor: str = "dashboard",
) -> RunRecord:
    record = load_run_record(run_id)
    if record is None:
        raise FileNotFoundError(f"Run not found: {run_id}")

    _append_metadata_event(
        record,
        "interventions",
        {
            "actor": actor,
            "message": message,
        },
    )
    record.metadata["last_intervention"] = message
    write_run_record(record)
    return record


def write_stage_record(record: StageRecord) -> Path:
    ensure_run_layout(record.run_id)
    record.updated_at = _utcnow_iso()
    path = _stage_path(record.run_id, record.stage_id)
    atomic_json_write(path, asdict(record))
    return path


def load_stage_record(run_id: str, stage_id: str) -> Optional[StageRecord]:
    payload = _read_json(_stage_path(run_id, stage_id))
    if not payload:
        return None
    return StageRecord(**payload)


def list_stage_records(run_id: str) -> List[StageRecord]:
    stage_dir = get_run_dir(run_id) / "stages"
    if not stage_dir.is_dir():
        return []

    records: List[StageRecord] = []
    for path in stage_dir.glob("*.json"):
        payload = _read_json(path)
        if not payload:
            continue
        try:
            records.append(StageRecord(**payload))
        except TypeError:
            continue
    records.sort(key=lambda record: record.created_at)
    return records


def write_unit_record(record: UnitRecord) -> Path:
    ensure_run_layout(record.run_id)
    record.updated_at = _utcnow_iso()
    path = _unit_path(record.run_id, record.stage_id, record.unit_id)
    atomic_json_write(path, asdict(record))
    return path


def load_unit_record(run_id: str, stage_id: str, unit_id: str) -> Optional[UnitRecord]:
    payload = _read_json(_unit_path(run_id, stage_id, unit_id))
    if not payload:
        return None
    return UnitRecord(**payload)


def list_unit_records(run_id: str) -> List[UnitRecord]:
    unit_dir = get_run_dir(run_id) / "units"
    if not unit_dir.is_dir():
        return []

    records: List[UnitRecord] = []
    for path in unit_dir.glob("*.json"):
        payload = _read_json(path)
        if not payload:
            continue
        try:
            records.append(UnitRecord(**payload))
        except TypeError:
            continue
    records.sort(key=lambda record: (record.stage_id, record.created_at))
    return records


def write_checkpoint(record: CheckpointRecord) -> Path:
    ensure_run_layout(record.run_id)
    path = _checkpoint_path(record.run_id, record.stage_id, record.unit_id)
    atomic_json_write(path, asdict(record))
    return path


def load_checkpoint(run_id: str, stage_id: str, unit_id: str) -> Optional[CheckpointRecord]:
    payload = _read_json(_checkpoint_path(run_id, stage_id, unit_id))
    if not payload:
        return None
    return CheckpointRecord(**payload)


def list_checkpoint_records(run_id: str) -> List[CheckpointRecord]:
    checkpoint_dir = get_run_dir(run_id) / "checkpoints"
    if not checkpoint_dir.is_dir():
        return []

    records: List[CheckpointRecord] = []
    for path in checkpoint_dir.glob("*.json"):
        payload = _read_json(path)
        if not payload:
            continue
        try:
            records.append(CheckpointRecord(**payload))
        except TypeError:
            continue
    records.sort(key=lambda record: record.created_at, reverse=True)
    return records


def find_latest_checkpoint(run_id: str) -> Optional[CheckpointRecord]:
    checkpoint_dir = get_run_dir(run_id) / "checkpoints"
    if not checkpoint_dir.is_dir():
        return None

    latest: Optional[CheckpointRecord] = None
    for path in checkpoint_dir.glob("*.json"):
        payload = _read_json(path)
        if not payload:
            continue
        candidate = CheckpointRecord(**payload)
        if latest is None or candidate.created_at > latest.created_at:
            latest = candidate
    return latest
