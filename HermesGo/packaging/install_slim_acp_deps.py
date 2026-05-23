"""Backward-compatible entry — delegates to install_slim_runtime_extras.py."""
from __future__ import annotations

import os
import subprocess
import sys

if __name__ == "__main__":
    script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "install_slim_runtime_extras.py")
    raise SystemExit(subprocess.call([sys.executable, script]))
