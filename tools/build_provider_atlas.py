#!/usr/bin/env python3
"""Build the raw RGBA provider atlas from the checked-in official PNGs."""

from pathlib import Path

from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "src" / "frontend" / "assets"
SOURCES = (ASSETS / "Claude.png", ASSETS / "Codex.png")
SLOT_SIZE = 256
OUTPUT = ASSETS / "provider-marks-512x256.rgba"


def main() -> None:
    atlas = Image.new("RGBA", (len(SOURCES) * SLOT_SIZE, SLOT_SIZE), (0, 0, 0, 0))
    for index, path in enumerate(SOURCES):
        with Image.open(path) as source:
            icon = source.convert("RGBA")
            icon.thumbnail((SLOT_SIZE, SLOT_SIZE), Image.Resampling.LANCZOS)
            x = index * SLOT_SIZE + (SLOT_SIZE - icon.width) // 2
            y = (SLOT_SIZE - icon.height) // 2
            atlas.alpha_composite(icon, (x, y))
    OUTPUT.write_bytes(atlas.tobytes())


if __name__ == "__main__":
    main()
