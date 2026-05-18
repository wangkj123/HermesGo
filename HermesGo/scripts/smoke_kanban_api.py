"""Smoke-test Kanban API against bundled hermes-agent + webui bridge."""
from __future__ import annotations

import io
import json
import os
import sys
from urllib.parse import urlparse

WEBUI_DIR = os.path.join(os.path.dirname(__file__), "..", "runtime", "hermes-webui")
AGENT_DIR = os.path.join(os.path.dirname(__file__), "..", "runtime", "hermes-agent")
TEST_HOME = os.path.join(AGENT_DIR, ".hermes-kanban-smoke")

os.environ.setdefault("HERMES_HOME", TEST_HOME)
sys.path.insert(0, AGENT_DIR)
sys.path.insert(0, WEBUI_DIR)

from api import routes  # noqa: E402


class _Handler:
    def __init__(self) -> None:
        self.status: int | None = None
        self.headers: dict[str, str] = {}
        self.wfile = io.BytesIO()

    def send_response(self, status: int) -> None:
        self.status = status

    def send_header(self, key: str, value: str) -> None:
        self.headers[key] = value

    def end_headers(self) -> None:
        pass

    def json(self) -> dict:
        return json.loads(self.wfile.getvalue().decode("utf-8"))


def _get(path: str) -> tuple[int, dict]:
    handler = _Handler()
    ok = routes.handle_get(handler, urlparse(path))
    assert ok, path
    assert handler.status is not None
    return handler.status, handler.json()


def main() -> int:
    os.makedirs(TEST_HOME, exist_ok=True)

    for path in (
        "/api/kanban/boards",
        "/api/kanban/config",
        "/api/kanban/board",
    ):
        status, body = _get(path)
        if status != 200:
            print(f"FAIL {path}: HTTP {status} {body}")
            return 1
        print(f"OK {path}: keys={list(body.keys())[:6]}")

    from api.kanban_bridge import handle_kanban_post

    handler = _Handler()
    handled = handle_kanban_post(
        handler,
        urlparse("/api/kanban/tasks"),
        {
            "title": "HermesGo smoke task",
            "assignee": "smoke",
            "tenant": "hermesgo",
            "priority": 1,
        },
    )
    if not handled or handler.status != 200:
        print(f"FAIL create task: handled={handled} status={handler.status} body={handler.wfile.getvalue()!r}")
        return 1
    task = handler.json().get("task") or {}
    task_id = task.get("id")
    print(f"OK create task: {task_id}")

    status, board = _get("/api/kanban/board")
    tasks = [
        task
        for column in board.get("columns") or []
        for task in column.get("tasks") or []
    ]
    if not any(t.get("id") == task_id for t in tasks):
        print(f"FAIL board missing created task {task_id}")
        return 1
    print(f"OK board lists {len(tasks)} task(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
