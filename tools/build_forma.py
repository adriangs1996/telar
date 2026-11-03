#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = ["fonttools==4.63.0"]
# ///
"""Rebuild Telar Forma Regular from its pinned base and approved glyph drawings."""

import argparse
import hashlib
import json
import unicodedata
from array import array
from pathlib import Path

from fontTools.misc.roundTools import otRound
from fontTools.pens.recordingPen import DecomposingRecordingPen
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.ttLib import TTFont
from fontTools.ttLib.tables._g_l_y_f import Glyph, GlyphCoordinates
from fontTools.ttLib.tables.ttProgram import Program

CELL = 575
CAP_HEIGHT = 684
X_HEIGHT = 520
FAMILY = "Telar Forma"
VERSION = "0.106"
SOURCE_SHA256 = "a0bf60ef0f83c5ed4d7a75d45838548b1f6873372dfac88f71804491898d138f"


def authored_outlines():
    drawings = {
        "J": [
            ("M", (100, 684)), ("L", (470, 684)), ("L", (470, 210)),
            ("Q", (470, 103), (410, 49)), ("Q", (350, -10), (255, -10)),
            ("Q", (159, -10), (75, 50)), ("L", (75, 140)),
            ("Q", (155, 70), (255, 70)), ("Q", (316, 70), (349, 107)),
            ("Q", (382, 144), (382, 210)), ("L", (382, 608)),
            ("L", (100, 608)), ("Z",),
        ],
        "l": [
            ("M", (65, 710)), ("L", (321, 710)), ("L", (321, 113)),
            ("Q", (321, 76), (356, 76)), ("L", (514, 76)),
            ("L", (514, 0)), ("L", (152, 0)), ("L", (152, 76)),
            ("L", (233, 76)), ("L", (233, 634)), ("L", (65, 634)), ("Z",),
        ],
        "4": [
            ("M", (360, 0)), ("L", (360, 145)), ("L", (40, 145)),
            ("L", (40, 240)), ("L", (310, 684)), ("L", (443, 684)),
            ("L", (443, 225)), ("L", (540, 225)), ("L", (540, 145)),
            ("L", (443, 145)), ("L", (443, 0)), ("Z",),
            ("M", (360, 575)), ("L", (127, 225)), ("L", (360, 225)), ("Z",),
        ],
        "&": [
            ("M", (200, -8)), ("Q", (110, -8), (65, 45)),
            ("Q", (25, 90), (25, 175)), ("Q", (25, 250), (70, 302)),
            ("Q", (100, 338), (170, 375)), ("L", (150, 402)),
            ("Q", (90, 480), (90, 550)), ("Q", (90, 620), (140, 660)),
            ("Q", (190, 704), (260, 704)), ("Q", (335, 704), (380, 660)),
            ("Q", (425, 620), (425, 555)), ("Q", (425, 500), (390, 460)),
            ("Q", (355, 420), (300, 385)), ("L", (410, 245)),
            ("Q", (439, 300), (455, 360)), ("L", (535, 360)),
            ("Q", (520, 245), (460, 180)), ("L", (600, 0)),
            ("L", (495, 0)), ("L", (400, 85)), ("Q", (300, -8), (200, -8)), ("Z",),
            ("M", (200, 72)), ("Q", (270, 72), (345, 145)),
            ("L", (218, 311)), ("Q", (170, 285), (140, 250)),
            ("Q", (110, 215), (110, 175)), ("Q", (110, 125), (135, 100)),
            ("Q", (160, 72), (200, 72)), ("Z",),
            ("M", (245, 445)), ("Q", (335, 495), (335, 555)),
            ("Q", (335, 595), (313, 620)), ("Q", (290, 645), (258, 645)),
            ("Q", (225, 645), (203, 622)), ("Q", (180, 598), (180, 560)),
            ("Q", (180, 518), (213, 475)), ("L", (245, 445)), ("Z",),
        ],
        "@": [
            ("M", (470, -80)), ("L", (300, -80)),
            ("Q", (170, -80), (95, 0)), ("Q", (25, 75), (25, 210)),
            ("L", (25, 390)), ("Q", (25, 535), (100, 615)),
            ("Q", (170, 690), (295, 690)), ("Q", (425, 690), (495, 615)),
            ("Q", (560, 540), (560, 405)), ("L", (560, 235)),
            ("Q", (560, 80), (450, 80)), ("Q", (390, 80), (370, 140)),
            ("Q", (330, 80), (265, 80)), ("Q", (155, 80), (155, 210)),
            ("L", (155, 335)), ("Q", (155, 470), (265, 470)),
            ("Q", (330, 470), (370, 415)), ("L", (370, 475)),
            ("L", (435, 475)), ("L", (435, 235)),
            ("Q", (435, 145), (460, 145)), ("Q", (495, 145), (495, 235)),
            ("L", (495, 405)), ("Q", (495, 515), (445, 570)),
            ("Q", (395, 625), (295, 625)), ("Q", (195, 625), (145, 570)),
            ("Q", (90, 510), (90, 390)), ("L", (90, 210)),
            ("Q", (90, 95), (140, 40)), ("Q", (195, -15), (300, -15)),
            ("L", (470, -15)), ("Z",),
            ("M", (275, 145)), ("Q", (370, 145), (370, 235)),
            ("L", (370, 315)), ("Q", (370, 405), (275, 405)),
            ("Q", (220, 405), (220, 315)), ("L", (220, 235)),
            ("Q", (220, 145), (275, 145)), ("Z",),
        ],
    }
    result = {}
    for char, drawing in drawings.items():
        pen = TTGlyphPen(None)
        for op, *points in drawing:
            if op == "M":
                pen.moveTo(points[0])
            elif op == "L":
                pen.lineTo(points[0])
            elif op == "Q":
                pen.qCurveTo(*points)
            else:
                pen.closePath()
        result[char] = pen.glyph()
    return result


def scale_layout(obj, sx, sy, seen=None):
    if seen is None:
        seen = set()
    if id(obj) in seen:
        return
    seen.add(id(obj))
    if isinstance(obj, (list, tuple)):
        for item in obj:
            scale_layout(item, sx, sy, seen)
    elif hasattr(obj, "__dict__"):
        for attr, value in vars(obj).items():
            if attr in {"XCoordinate", "XAdvance", "XPlacement", "Coordinate"} and isinstance(value, int):
                setattr(obj, attr, otRound(value * sx))
            elif attr in {"YCoordinate", "YAdvance", "YPlacement"} and isinstance(value, int):
                setattr(obj, attr, otRound(value * sy))
            else:
                scale_layout(value, sx, sy, seen)


def redraw(glyph_set, name, transform):
    recording = DecomposingRecordingPen(glyph_set)
    glyph_set[name].draw(recording)
    pen = TTGlyphPen(None)
    for operation, points in recording.value:
        getattr(pen, operation)(*(None if point is None else transform(*point) for point in points))
    return pen.glyph()


def rename(font, family):
    postscript = family.replace(" ", "") + "-Regular"
    names = {
        1: family,
        2: "Regular",
        3: postscript + "-" + VERSION,
        4: family + " Regular",
        5: "Version " + VERSION,
        6: postscript,
        8: "Telar",
        10: "Monospaced Regular face with adjusted metrics and authored glyph drawings.",
        16: family,
        17: "Regular",
    }
    for identifier, text in names.items():
        font["name"].removeNames(nameID=identifier)
        for platform, encoding, language in ((3, 1, 0x409), (1, 0, 0)):
            font["name"].setName(text, identifier, platform, encoding, language)
    font["head"].fontRevision = float(VERSION)


def apply_drawings(font, drawings_path):
    drawings = json.loads(drawings_path.read_text())
    if drawings["version"] != VERSION or drawings["base_sha256"] != SOURCE_SHA256:
        raise ValueError("Glyph drawings must match the pinned base and font version")

    glyph_names = set(font.getGlyphOrder())
    for name, drawing in drawings["glyphs"].items():
        if name not in glyph_names:
            raise ValueError(f"Unknown glyph drawing: {name}")

        glyph = Glyph()
        glyph.numberOfContours = len(drawing["end_points"])
        glyph.endPtsOfContours = drawing["end_points"]
        glyph.coordinates = GlyphCoordinates(drawing["coordinates"])
        glyph.flags = array("B", drawing["flags"])
        glyph.program = Program()
        glyph.program.fromBytecode([])
        glyph.recalcBounds(font["glyf"])
        font["glyf"][name] = glyph
        font["hmtx"][name] = tuple(drawing["metrics"])

    for identifier, value in drawings["names"].items():
        font["name"].removeNames(nameID=int(identifier))
        for platform, encoding, language in ((3, 1, 0x409), (1, 0, 0)):
            font["name"].setName(value, int(identifier), platform, encoding, language)

    return len(drawings["glyphs"])


def build(source_path, output, drawings_path):
    original_bytes = source_path.read_bytes()
    if hashlib.sha256(original_bytes).hexdigest() != SOURCE_SHA256:
        raise ValueError("Expected the pinned JetBrains Mono Regular source")
    source = TTFont(source_path, recalcTimestamp=False)
    result = TTFont(source_path, recalcTimestamp=False)
    cmap = source.getBestCmap()
    glyph_set = source.getGlyphSet()
    glyph_names = set(source.getGlyphOrder())
    sx = CELL / source["hmtx"][cmap[ord("m")]][0]
    sy = CAP_HEIGHT / source["OS/2"].sCapHeight
    old_xheight = source["OS/2"].sxHeight
    lowercases = {
        name for codepoint, name in cmap.items()
        if unicodedata.category(chr(codepoint)) == "Ll"
        and "LATIN" in unicodedata.name(chr(codepoint), "")
    }

    def transform(x, y, lowercase):
        if lowercase and 0 < y < source["OS/2"].sCapHeight:
            if y <= old_xheight:
                y = y * X_HEIGHT / old_xheight
            else:
                y = X_HEIGHT + (y - old_xheight) * (CAP_HEIGHT - X_HEIGHT) / (source["OS/2"].sCapHeight - old_xheight)
        else:
            y *= sy
        return otRound(x * sx), otRound(y)

    for name in source.getGlyphOrder():
        input_name = name
        if name + ".cv03" in glyph_names:
            input_name = name + ".cv03"
        elif name == "zero" and "zero.zero" in glyph_names:
            input_name = "zero.zero"
        glyph = redraw(glyph_set, input_name, lambda x, y: transform(x, y, name in lowercases))
        glyph.recalcBounds(result["glyf"])
        result["glyf"][name] = glyph
        width, bearing = source["hmtx"][name]
        result["hmtx"][name] = otRound(width * sx), getattr(glyph, "xMin", otRound(bearing * sx))

    authored = authored_outlines()
    for char, glyph in authored.items():
        name = cmap[ord(char)]
        glyph.recalcBounds(result["glyf"])
        result["glyf"][name] = glyph
        result["hmtx"][name] = CELL, glyph.xMin

    for tag in ("GPOS", "GDEF"):
        if tag in result:
            scale_layout(result[tag].table, sx, sy)
    for attr in ("ascent", "descent", "lineGap"):
        setattr(result["hhea"], attr, otRound(getattr(result["hhea"], attr) * sy))
    for attr in ("sTypoAscender", "sTypoDescender", "sTypoLineGap", "usWinAscent", "usWinDescent", "ySubscriptYSize", "ySubscriptYOffset", "ySuperscriptYSize", "ySuperscriptYOffset", "yStrikeoutSize", "yStrikeoutPosition"):
        setattr(result["OS/2"], attr, otRound(getattr(result["OS/2"], attr) * sy))
    for attr in ("xAvgCharWidth", "ySubscriptXSize", "ySubscriptXOffset", "ySuperscriptXSize", "ySuperscriptXOffset"):
        setattr(result["OS/2"], attr, otRound(getattr(result["OS/2"], attr) * sx))
    result["OS/2"].sxHeight = X_HEIGHT
    result["OS/2"].sCapHeight = CAP_HEIGHT
    for attr in ("underlinePosition", "underlineThickness"):
        setattr(result["post"], attr, otRound(getattr(result["post"], attr) * sy))
    for tag in ("fpgm", "prep", "cvt ", "DSIG"):
        if tag in result:
            del result[tag]
    approved_drawings = apply_drawings(result, drawings_path)
    rename(result, FAMILY)
    result.save(output)

    checked = TTFont(output, checkChecksums=2)
    assert checked.getGlyphOrder() == source.getGlyphOrder()
    assert checked.getBestCmap() == source.getBestCmap()
    assert checked["GSUB"].compile(checked) == source["GSUB"].compile(source)
    assert checked["OS/2"].fsType == source["OS/2"].fsType
    assert all(checked["hmtx"][cmap[codepoint]][0] == CELL for codepoint in range(32, 127))
    assert source_path.read_bytes() == original_bytes
    report = {
        "family": FAMILY,
        "version": VERSION,
        "input": str(source_path.resolve()),
        "input_sha256": hashlib.sha256(original_bytes).hexdigest(),
        "drawings_sha256": hashlib.sha256(drawings_path.read_bytes()).hexdigest(),
        "output_sha256": hashlib.sha256(output.read_bytes()).hexdigest(),
        "cell": CELL,
        "cap_height": CAP_HEIGHT,
        "x_height": X_HEIGHT,
        "glyph_count": len(checked.getGlyphOrder()),
        "authored_drawings": list(authored),
        "approved_glyph_drawings": approved_drawings,
        "checks": ["source unchanged", "cmap retained", "glyph order retained", "GSUB retained", "uniform ASCII advances", "source embedding flags retained"],
    }
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=root / "src/assets/JetBrainsMono-Regular.ttf")
    parser.add_argument("--drawings", type=Path, default=root / "src/assets/TelarForma-glyphs.json")
    parser.add_argument("--output", type=Path, default=root / "src/assets/TelarForma-Regular.ttf")
    arguments = parser.parse_args()
    build(arguments.source, arguments.output, arguments.drawings)
