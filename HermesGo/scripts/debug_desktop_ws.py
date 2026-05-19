"""Debug Desktop WS: log every frame until close."""
from __future__ import annotations

import asyncio
import json
import re
import sys
import urllib.request


def token() -> str:
    t = urllib.request.urlopen("http://127.0.0.1:9119/env?quick=1", timeout=12).read().decode()
    m = re.search(r'__HERMES_SESSION_TOKEN__\s*=\s*["\']([^"\']+)', t)
    if not m:
        raise RuntimeError("no token")
    return m.group(1)


async def main() -> int:
    import websockets

    uri = f"ws://127.0.0.1:9119/api/ws?token={token()}"
    n = 0
    try:
        async with websockets.connect(uri, open_timeout=15) as ws:
            while n < 200:
                try:
                    raw = await asyncio.wait_for(ws.recv(), timeout=90)
                except asyncio.TimeoutError:
                    print(f"[{n}] TIMEOUT")
                    break
                n += 1
                try:
                    msg = json.loads(raw)
                except Exception:
                    print(f"[{n}] NON-JSON: {raw[:200]!r}")
                    continue
                mid = msg.get("id")
                method = msg.get("method")
                err = msg.get("error")
                ptype = (msg.get("params") or {}).get("type")
                payload = (msg.get("params") or {}).get("payload") or {}
                text = ""
                if isinstance(payload, dict):
                    text = str(payload.get("text") or payload.get("content") or "")[:80]
                print(
                    f"[{n}] id={mid} method={method} event={ptype} err={err} text={text!r}"
                )
                if ptype == "error":
                    print(f"     error payload={json.dumps((msg.get('params') or {}), ensure_ascii=False)[:500]}")
                if n == 1:
                    rid = 1
                    await ws.send(
                        json.dumps(
                            {
                                "jsonrpc": "2.0",
                                "id": rid,
                                "method": "session.create",
                                "params": {},
                            }
                        )
                    )
                elif n == 2:
                    # wait for session.create response - may be n=2 or later
                    pass
                if mid == 1 and msg.get("result"):
                    sid = (msg.get("result") or {}).get("session_id")
                    if sid:
                        print(f"  -> session_id={sid}, sending prompt.submit")
                        await ws.send(
                            json.dumps(
                                {
                                    "jsonrpc": "2.0",
                                    "id": 2,
                                    "method": "prompt.submit",
                                    "params": {"session_id": sid, "text": "hello"},
                                }
                            )
                        )
                if ptype == "message.complete":
                    print("  -> turn complete, exiting")
                    break
    except Exception as exc:
        print(f"WS ended: {type(exc).__name__}: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
