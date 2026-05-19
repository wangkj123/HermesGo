import json
from pathlib import Path

from agent.profile_pool import (
    acquire_profile_lease,
    ensure_profile_pool_layout,
    get_profile_lease_path,
    get_profile_runtime_path,
    load_profile_lease,
    load_profile_runtime,
    mark_profile_cooldown,
    release_profile_lease,
)


def test_profile_pool_layout_created(tmp_path, monkeypatch):
    monkeypatch.setattr(Path, "home", lambda: tmp_path)
    monkeypatch.setenv("HERMES_HOME", str(tmp_path / ".hermes"))

    root = ensure_profile_pool_layout()

    assert root == tmp_path / ".hermes" / "profile-pool"
    assert (root / "profiles").is_dir()
    assert (root / "leases").is_dir()


def test_runtime_record_created_lazily(tmp_path, monkeypatch):
    hermes_home = tmp_path / ".hermes"
    hermes_home.mkdir()
    monkeypatch.setattr(Path, "home", lambda: tmp_path)
    monkeypatch.setenv("HERMES_HOME", str(hermes_home))

    record = load_profile_runtime("default")

    assert record.profile_name == "default"
    assert record.status == "available"
    assert get_profile_runtime_path("default").exists()


def test_acquire_and_release_profile_lease(tmp_path, monkeypatch):
    hermes_home = tmp_path / ".hermes"
    hermes_home.mkdir()
    monkeypatch.setattr(Path, "home", lambda: tmp_path)
    monkeypatch.setenv("HERMES_HOME", str(hermes_home))

    lease = acquire_profile_lease("default", owner_task_id="task-1", owner_role="implementer", ttl_seconds=120)
    assert lease is not None
    assert lease.state == "leased"

    runtime = load_profile_runtime("default")
    assert runtime.status == "leased"

    released = release_profile_lease("default", lease_id=lease.lease_id)
    assert released.state == "available"
    assert released.released_at is not None

    runtime = load_profile_runtime("default")
    assert runtime.status == "available"


def test_cooldown_blocks_acquire_until_cleared(tmp_path, monkeypatch):
    hermes_home = tmp_path / ".hermes"
    hermes_home.mkdir()
    monkeypatch.setattr(Path, "home", lambda: tmp_path)
    monkeypatch.setenv("HERMES_HOME", str(hermes_home))

    mark_profile_cooldown("default", seconds=300, reason="provider-429")
    blocked = acquire_profile_lease("default", owner_task_id="task-2", owner_role="tester", ttl_seconds=60)

    assert blocked is None
    lease = load_profile_lease("default")
    assert lease.state == "cooldown"
    assert lease.reason == "provider-429"
    assert get_profile_lease_path("default").exists()
