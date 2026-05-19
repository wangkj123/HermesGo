"""Thread-safe helpers for scheduling coroutines onto a running event loop."""
from __future__ import annotations

import asyncio
from typing import Any, Coroutine, TypeVar

T = TypeVar("T")


def safe_schedule_threadsafe(
    coro: Coroutine[Any, Any, T],
    loop: asyncio.AbstractEventLoop | None,
) -> asyncio.Future[T] | None:
    """Schedule *coro* on *loop* from a worker thread.

    Returns a Future, or None when the loop is missing, closed, or not accepting work.
    """
    if loop is None:
        return None
    try:
        if loop.is_closed():
            return None
    except Exception:
        return None
    try:
        return asyncio.run_coroutine_threadsafe(coro, loop)
    except RuntimeError:
        return None
