"""Capture Dashboard / WebUI / Desktop-embedded dashboard screenshots via HTTP."""
from __future__ import annotations

import argparse
import os
import sys
import time
import urllib.request

try:
    from playwright.sync_api import sync_playwright
except ImportError:
    sync_playwright = None  # type: ignore


def _wait_url(url: str, timeout: float = 60.0) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(url, timeout=3) as resp:
                if 200 <= resp.status < 500:
                    return True
        except Exception:
            pass
        time.sleep(1)
    return False


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    out = os.path.abspath(args.out)
    os.makedirs(out, exist_ok=True)

    targets = [
        ("01-dashboard-9119.png", "http://127.0.0.1:9119/"),
        ("02-webui-8787.png", "http://127.0.0.1:8787/"),
    ]
    for port in range(9120, 9200):
        targets.append((f"03-desktop-embedded-{port}.png", f"http://127.0.0.1:{port}/"))

    if sync_playwright is None:
        print("SKIP playwright not installed; writing placeholder notes")
        for name, url in targets:
            ok = _wait_url(url, timeout=8)
            note = os.path.join(out, name.replace(".png", ".txt"))
            with open(note, "w", encoding="utf-8") as f:
                f.write(f"url={url}\nreachable={ok}\n")
            print(f"{'OK' if ok else 'FAIL'} {url}")
        return 0

    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        page = browser.new_page(viewport={"width": 1440, "height": 900})
        for name, url in targets:
            if not _wait_url(url, timeout=45):
                print(f"SKIP unreachable {url}")
                continue
            try:
                page.goto(url, wait_until="networkidle", timeout=60000)
                page.screenshot(path=os.path.join(out, name), full_page=False)
                print(f"OK screenshot {name}")
                break
            except Exception as exc:
                print(f"WARN {url}: {exc}")
        browser.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
