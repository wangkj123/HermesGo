from __future__ import annotations

import argparse
import ctypes
import os
import time
from ctypes import wintypes
from pathlib import Path

import cv2
import numpy as np
from PIL import ImageGrab

USER32 = ctypes.windll.user32
SW_RESTORE = 9
ENUM_WINDOWS_PROC = ctypes.WINFUNCTYPE(ctypes.c_bool, wintypes.HWND, wintypes.LPARAM)


def enumerate_windows():
    windows = []

    @ENUM_WINDOWS_PROC
    def _enum(hwnd, _lparam):
        length = USER32.GetWindowTextLengthW(hwnd)
        if length > 0:
            buffer = ctypes.create_unicode_buffer(length + 1)
            USER32.GetWindowTextW(hwnd, buffer, length + 1)
            title = buffer.value.strip()
            if title:
                windows.append((hwnd, title))
        return True

    USER32.EnumWindows(_enum, 0)
    return windows


def find_window(title_hint: str):
    title_hint_lower = title_hint.lower()
    windows = enumerate_windows()
    exact = [item for item in windows if item[1].lower() == title_hint_lower]
    if exact:
        return exact[0]
    partial = [item for item in windows if title_hint_lower in item[1].lower()]
    if partial:
        return partial[0]
    return None


def get_window_rect(hwnd):
    rect = wintypes.RECT()
    if not USER32.GetWindowRect(hwnd, ctypes.byref(rect)):
        raise RuntimeError("GetWindowRect failed")
    return rect.left, rect.top, rect.right, rect.bottom


def record_region(region, output_path: Path, duration: float, fps: int):
    left, top, right, bottom = region
    width = max(1, right - left)
    height = max(1, bottom - top)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    writer = cv2.VideoWriter(
        str(output_path),
        cv2.VideoWriter_fourcc(*"mp4v"),
        float(fps),
        (width, height),
    )
    if not writer.isOpened():
        raise RuntimeError(f"Unable to open video writer for {output_path}")

    frame_count = max(1, int(round(duration * fps)))
    delay = 1.0 / fps
    for _ in range(frame_count):
        image = ImageGrab.grab(bbox=(left, top, right, bottom))
        frame = cv2.cvtColor(np.array(image), cv2.COLOR_RGB2BGR)
        writer.write(frame)
        time.sleep(delay)

    writer.release()


def main():
    parser = argparse.ArgumentParser(description="Record a HermesGo tutorial clip.")
    parser.add_argument("--window-title", default="HermesGo 启动器", help="Window title hint.")
    parser.add_argument("--output", required=True, help="Output mp4 path.")
    parser.add_argument("--duration", type=float, default=4.0, help="Recording duration in seconds.")
    parser.add_argument("--fps", type=int, default=8, help="Frames per second.")
    parser.add_argument(
        "--screen",
        action="store_true",
        help="Record the whole screen instead of a single window.",
    )
    args = parser.parse_args()

    if os.name != "nt":
        raise SystemExit("This recorder is intended for Windows only.")

    if args.screen:
        region = USER32.GetSystemMetrics(0), USER32.GetSystemMetrics(1)
        region = (0, 0, region[0], region[1])
    else:
        found = find_window(args.window_title)
        if not found:
            raise SystemExit(f"Window not found: {args.window_title}")
        hwnd, _title = found
        USER32.ShowWindow(hwnd, SW_RESTORE)
        USER32.SetForegroundWindow(hwnd)
        region = get_window_rect(hwnd)

    record_region(region, Path(args.output), args.duration, args.fps)
    print(f"Saved recording: {args.output}")


if __name__ == "__main__":
    main()
