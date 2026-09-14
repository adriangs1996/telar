#!/usr/bin/env python3
"""Rasterize the T3 Code provider SVGs into the sidebar atlas.

Claude and Pi retain their colors. OpenAI is white so the renderer can tint it
with the theme's foreground color.

Requires rsvg-convert and Pillow. Run from any directory; output is reproducible
with librsvg 2.62.3 and Pillow 12.2.0.
"""
from io import BytesIO
from pathlib import Path
import subprocess

from PIL import Image


ASSETS = Path(__file__).resolve().parents[1] / "src" / "assets"
SOURCES = ("Claude-symbol.svg", "OpenAI-symbol.svg", "Pi-symbol.svg")
SIDE = 64


def main():
    atlas = Image.new("RGBA", (SIDE * len(SOURCES), SIDE))
    for index, name in enumerate(SOURCES):
        png = subprocess.check_output([
            "rsvg-convert", "--width", str(SIDE), "--height", str(SIDE),
            "--keep-aspect-ratio", str(ASSETS / name),
        ])
        with Image.open(BytesIO(png)) as source:
            symbol = source.convert("RGBA")
            atlas.alpha_composite(symbol, (index * SIDE + (SIDE - symbol.width) // 2,
                                           (SIDE - symbol.height) // 2))
    (ASSETS / "provider-symbols-192x64.rgba").write_bytes(atlas.tobytes())


if __name__ == "__main__":
    main()
