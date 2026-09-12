#!/usr/bin/env python3
"""Bounded PTY output fixtures for native renderer slot measurements.

Example: python3 tools/gui_slot_workload.py --mode full --rate 120 --seconds 12
The workload starts after window sizing has settled and folds missed ticks.
"""
import argparse
import json
import os
from pathlib import Path
import signal
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--mode', choices=['scroll', 'full'], required=True)
    parser.add_argument('--rate', type=int, default=120)
    parser.add_argument('--seconds', type=float, default=12)
    parser.add_argument('--size-file', type=Path)
    parser.add_argument('--initial-delay', type=float, default=2)
    parser.add_argument('--marker', action='store_true', help='timestamp a sequence encoded in the first cell background')
    args = parser.parse_args()
    if not 1 <= args.rate <= 240 or not 1 <= args.seconds <= 60:
        parser.error('rate must be 1..240 and seconds 1..60')
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    os.write(1, b'\x1b[?25l\x1b[2J\x1b[H')
    time.sleep(args.initial_delay)
    started = time.monotonic()
    interval = 1 / args.rate
    deadline = started
    frames = total_bytes = skipped = 0
    updates = []
    size = os.get_terminal_size(1)
    cols = min(size.columns, 512)
    rows = min(size.lines, 200)
    if args.marker:
        # Keep the marker outside scrolling and partial full-screen writes.
        os.write(1, f'\x1b[2;{rows}r\x1b[2;1H'.encode())
    try:
        while time.monotonic() - started < args.seconds:
            digit = str(frames % 10)
            if args.mode == 'scroll':
                line = (f'{frames:08d} ' + digit * max(1, cols - 10) + '\r\n').encode()
                payload = line * 4
            else:
                lines = []
                for row in range(2 if args.marker else 1, rows + 1):
                    content = f'{frames:08d}:{row:03d} ' + digit * max(1, cols - 14)
                    lines.append(f'\x1b[{row};1H{content}')
                payload = ''.join(lines).encode()
            if args.marker:
                sequence = frames + 1
                payload += f'\x1b7\x1b[1;1H\x1b[48;2;128;{sequence >> 8};{sequence & 255}m \x1b[0m\x1b8'.encode()
            write_started = time.monotonic()
            # Account for short writes instead of silently truncating a redraw.
            remaining = memoryview(payload)
            while remaining:
                written = os.write(1, remaining)
                remaining = remaining[written:]
            if args.marker:
                updates.append([sequence, write_started, time.monotonic()])
            frames += 1
            total_bytes += len(payload)
            deadline += interval
            now = time.monotonic()
            if deadline < now:
                missed = int((now - deadline) / interval) + 1
                deadline += missed * interval
                skipped += missed
            time.sleep(max(0, deadline - time.monotonic()))
    finally:
        if args.size_file:
            args.size_file.write_text(json.dumps(dict(
                mode=args.mode, requested_rate_hz=args.rate,
                cells=[size.columns, size.lines], rendered_cells=[cols, rows],
                started_monotonic_s=started, finished_monotonic_s=time.monotonic(),
                output_batches=frames, output_bytes=total_bytes, skipped_ticks=skipped,
                marker_updates=updates if args.marker else None,
            ), indent=2) + '\n')
    # Keep the terminal stable until the measurement driver closes its window.
    while True:
        time.sleep(60)


if __name__ == '__main__':
    main()
