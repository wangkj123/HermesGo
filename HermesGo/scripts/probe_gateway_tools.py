"""Print tools.show from live gateway WS."""
from __future__ import annotations

import asyncio
import json
import re
import sys
import urllib.request

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass


async def main() -> int:
    import websockets

    with urllib.request.urlopen("http://127.0.0.1:9119/env?quick=1", timeout=10) as resp:
        text = resp.read().decode("utf-8", errors="replace")
    m = re.search(r"__HERMES_SESSION_TOKEN__\s*=\s*['\"]([^'\"]+)", text)
    if not m:
        print("no token")
        return 1
    token = m.group(1)
    uri = f"ws://127.0.0.1:9119/api/ws?token={token}"
    async with websockets.connect(uri, open_timeout=15) as ws:
        try:
            await asyncio.wait_for(ws.recv(), timeout=5)
        except Exception:
            pass
        await ws.send(
            json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools.show", "params": {}})
        )
        while True:
            msg = json.loads(await asyncio.wait_for(ws.recv(), timeout=30))
            if msg.get("id") == 1:
                secs = (msg.get("result") or {}).get("sections") or []
                names: list[str] = []
                for block in secs:
                    if isinstance(block, dict):
                        for item in block.get("tools") or []:
                            if isinstance(item, dict) and item.get("name"):
                                names.append(str(item["name"]))
                print("count", len(names))
                print("web_search", "web_search" in names)
                print("names", sorted(names))
                return 0 if "web_search" in names else 2


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
