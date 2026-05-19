"""Print Desktop WS setup.status / setup.runtime_check (same path as Hermes Desktop)."""
from __future__ import annotations

import asyncio
import json
import re
import urllib.request


def _token() -> str:
    text = urllib.request.urlopen("http://127.0.0.1:9119/env?quick=1", timeout=10).read().decode()
    m = re.search(r"__HERMES_SESSION_TOKEN__\s*=\s*['\"]([^'\"]+)", text)
    if not m:
        raise RuntimeError("session token missing")
    return m.group(1)


async def _main() -> None:
    import websockets

    uri = f"ws://127.0.0.1:9119/api/ws?token={_token()}"
    async with websockets.connect(uri, open_timeout=12) as ws:
        await ws.recv()
        for i, method in enumerate(("setup.status", "setup.runtime_check"), start=1):
            await ws.send(
                json.dumps({"jsonrpc": "2.0", "id": i, "method": method, "params": {}})
            )
            while True:
                msg = json.loads(await ws.recv())
                if msg.get("id") == i:
                    print(f"\n=== {method} ===")
                    print(json.dumps(msg.get("result") or msg.get("error"), indent=2, ensure_ascii=False))
                    break


if __name__ == "__main__":
    asyncio.run(_main())
