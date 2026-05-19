"""Exit 0 when Dashboard :9119 reports gateway_running=true."""
from __future__ import annotations

import json
import os
import re
import sys
import urllib.request

_RUNTIME = os.environ.get("HERMES_RUNTIME_DIR", "")
if _RUNTIME:
    sys.path.insert(0, _RUNTIME)

DASHBOARD = os.environ.get("HERMES_DASHBOARD_URL", "http://127.0.0.1:9119/")


def main() -> int:
    try:
        html = urllib.request.urlopen(DASHBOARD, timeout=5).read().decode("utf-8", "replace")
    except Exception:
        return 1
    m = re.search(r"__HERMES_SESSION_TOKEN__\s*=\s*['\"]([^'\"]+)", html)
    if not m:
        return 1
    token = m.group(1)
    base = DASHBOARD.rstrip("/")
    req = urllib.request.Request(
        f"{base}/api/status",
        headers={"Authorization": f"Bearer {token}"},
    )
    data = json.loads(urllib.request.urlopen(req, timeout=8).read().decode())
    return 0 if data.get("gateway_running") else 1


if __name__ == "__main__":
    raise SystemExit(main())
