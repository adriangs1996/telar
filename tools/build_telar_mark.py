#!/usr/bin/env python3
"""Build the raw RGBA telar mark from its checked-in PNG rasterization."""

from pathlib import Path

from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "src" / "frontend" / "assets"
SOURCE = ASSETS / "telar-mark-64.png"
SIZE = 64
OUTPUT = ASSETS / f"telar-mark-{SIZE}.rgba"


def main() -> None:
    with Image.open(SOURCE) as source:
        mark = source.convert("RGBA")
        if mark.size != (SIZE, SIZE):
            raise SystemExit(f"expected a {SIZE}x{SIZE} source, got {mark.size}")
        OUTPUT.write_bytes(mark.tobytes())


if __name__ == "__main__":
    main()
