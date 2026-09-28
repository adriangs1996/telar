#!/usr/bin/env python3
"""Render every telar icon file from the three brand sources in src/assets.

- telar-icon.svg: the weaver in her web, for 128 px and up.
- telar-mark.svg: the weaver alone, drawn for 64 px and down.
- telar-mark-mono.svg: the weaver in one color, without a container.

Outputs the top bar and TUI mark (telar-mark-64.png and its raw RGBA), the
macOS .icns (small sizes from the mark, large ones from the icon), the Linux
PNG and the site's brand files. Requires rsvg-convert and Pillow; iconutil
builds the .icns on macOS and is skipped elsewhere. Run from any directory.
"""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "src" / "assets"
ICON = ASSETS / "telar-icon.svg"
MARK = ASSETS / "telar-mark.svg"
MONO = ASSETS / "telar-mark-mono.svg"
MARK_SIDE = 64
# Sizes at or below this come from the small mark; larger ones from the icon.
MARK_MAX_SIDE = 64
# iconutil's names for each pixel size of a macOS iconset.
ICONSET = {
    "icon_16x16.png": 16,
    "icon_16x16@2x.png": 32,
    "icon_32x32.png": 32,
    "icon_32x32@2x.png": 64,
    "icon_128x128.png": 128,
    "icon_128x128@2x.png": 256,
    "icon_256x256.png": 256,
    "icon_256x256@2x.png": 512,
    "icon_512x512.png": 512,
    "icon_512x512@2x.png": 1024,
}


def render(source: Path, side: int, output: Path) -> None:
    subprocess.run(["rsvg-convert", "-w", str(side), "-h", str(side), "-o", str(output), str(source)], check=True)


def render_for_size(side: int, output: Path) -> None:
    render(MARK if side <= MARK_MAX_SIDE else ICON, side, output)


def build_mark() -> None:
    png = ASSETS / f"telar-mark-{MARK_SIDE}.png"
    render(MARK, MARK_SIDE, png)
    with Image.open(png) as source:
        mark = source.convert("RGBA")
        (ASSETS / f"telar-mark-{MARK_SIDE}.rgba").write_bytes(mark.tobytes())


def build_icns() -> None:
    if shutil.which("iconutil") is None:
        print("iconutil not found: packaging/macos/telar.icns left unchanged", file=sys.stderr)
        return

    with tempfile.TemporaryDirectory() as directory:
        iconset = Path(directory) / "telar.iconset"
        iconset.mkdir()
        for name, side in ICONSET.items():
            render_for_size(side, iconset / name)
        subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(ROOT / "packaging" / "macos" / "telar.icns")], check=True)


def build_site() -> None:
    brand = ROOT / "site" / "public" / "brand"
    shutil.copyfile(ICON, brand / "telar-icon.svg")
    shutil.copyfile(MARK, brand / "telar-icon-small.svg")
    shutil.copyfile(MONO, brand / "telar-mark.svg")
    shutil.copyfile(MONO, brand / "telar-mark-small.svg")
    render(ICON, 1024, brand / "telar-icon-1024.png")
    render(ICON, 512, brand / "telar-icon-512.png")
    shutil.copyfile(MARK, ROOT / "site" / "app" / "icon.svg")
    render(ICON, 180, ROOT / "site" / "app" / "apple-icon.png")


def main() -> None:
    build_mark()
    build_icns()
    render(ICON, 512, ROOT / "packaging" / "linux" / "telar.png")
    build_site()


if __name__ == "__main__":
    main()
