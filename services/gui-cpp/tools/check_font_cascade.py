import argparse
import hashlib
import json
from pathlib import Path
import random
import struct
import subprocess

from check_font_shaping import include_paths
from check_text_fit import unicode_facade


reference_probe = r'''
const std = @import("std");
const assets = @import("assets");
const gfx = @import("gfx");
const Rect = gfx.Rect;
const GlyphAtlas = @import("src/gui/text/GlyphAtlas.zig");
const FontRuns = @import("src/gui/text/FontRuns.zig");
const font_id = @import("src/gui/text/font_id.zig");
const TextFit = @import("TextFit.zig");
const Canvas = @import("Canvas.zig");
extern "c" fn read(c_int, [*]u8, usize) isize;
extern "c" fn write(c_int, [*]const u8, usize) isize;
pub export fn telar_glyph_rasterizer_create(_: *const anyopaque) ?*anyopaque { return null; }
pub export fn telar_glyph_rasterizer_destroy(_: *anyopaque) void { @panic("Optical rasterization is outside this probe"); }
__TRANSFORM__
fn readBytes(bytes: []u8) bool {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = read(0, bytes[offset..].ptr, bytes.len - offset);
        if (count <= 0) return false;
        offset += @intCast(count);
    }
    return true;
}
fn input(comptime T: type) !T {
    var result: T = undefined;
    if (!readBytes(std.mem.asBytes(&result))) return error.IncompleteInput;
    return result;
}
fn output(bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = write(1, bytes[offset..].ptr, bytes.len - offset);
        if (count <= 0) return error.WriteFailed;
        offset += @intCast(count);
    }
}
fn value(number: anytype) !void { try output(std.mem.asBytes(&number)); }
fn text(bytes: []const u8) !void {
    try value(@as(u16, @intCast(bytes.len)));
    try output(bytes);
}
fn role(raw: u32) font_id.Id {
    return switch (raw) { 0 => .sans, 1 => .sans_semibold, 2 => .primary, 3 => .text, 4 => .symbols, else => unreachable };
}
fn roleNumber(id: font_id.Id) u32 {
    return switch (id) { .sans => 0, .sans_semibold => 1, .primary => 2, .text => 3, .symbols => 4, else => @as(u32, @intFromEnum(id)) };
}
pub fn main() !void {
    const font_index = try input(u32);
    const fonts = [_][]const u8{ assets.jetbrains_mono, assets.plex_sans, assets.nerd_symbols };
    var atlas = try GlyphAtlas.init(std.heap.page_allocator, .{ .font = fonts[font_index], .pixel_height = 13, .side = GlyphAtlas.max_side });
    defer atlas.deinit();
    var bytes: [4096]u8 = undefined;
    while (true) {
        var kind: u32 = 0;
        if (!readBytes(std.mem.asBytes(&kind))) break;
        if (kind == 1) {
            const ink = try input(Rect);
            const cell = try input(Rect);
            const transform = GlyphTransform.fit(ink, cell);
            try value([3]f32{ transform.x, transform.y, transform.scale });
            continue;
        }
        const preferred = role(try input(u32));
        const height: u16 = @intCast(try input(u32));
        const width = try input(f32);
        const length = try input(u16);
        if (length > bytes.len or !readBytes(bytes[0..length])) return error.InvalidText;
        const label = bytes[0..length];
        var canvas: Canvas = .{ .atlas = &atlas, .preferred = preferred, .height = height };
        const advance = canvas.measure(.{ .text = label }) catch {
            try value(@as(u32, 2));
            continue;
        };
        const fit: TextFit = .{ .canvas = &canvas, .width = width };
        var fitted: [TextFit.max_bytes]u8 = undefined;
        const shown = try fit.fit(.{ .text = label }, &fitted);
        try value(@as(u32, 1));
        try value(advance);
        try text(shown);
        var runs: FontRuns = .{ .fonts = &atlas.fonts, .iterator = .{ .bytes = label }, .preferred = preferred };
        while (runs.next()) |span| {
            const id = switch (span.source) { .font => |id| id, else => return error.ProceduralTextOutsideOracle };
            try text(span.text);
            try value(roleNumber(id));
            try value(if (id.fitted()) span.columns else @as(u32, 0));
        }
        try text("");
    }
}
'''


canvas_facade = r'''
const GlyphAtlas = @import("src/gui/text/GlyphAtlas.zig");
const font_id = @import("src/gui/text/font_id.zig");
const Label = @import("Label.zig");
const Canvas = @This();
atlas: *GlyphAtlas,
preferred: font_id.Id,
height: u16,
pub fn measure(self: *Canvas, label: Label) !f32 {
    return self.atlas.measure(.{ .text = label.text, .face = self.preferred, .pixel_height = self.height, .x = 0, .y = 0, .color = .{ .r = 1, .g = 1, .b = 1 } });
}
'''


def text_request(label, preferred, height, width):
    return struct.pack("<3IfH", 0, preferred, height, width, len(label)) + label


def requests():
    labels = ["", "AVATAR fi ffi", "Crème · descripción", "⎇ worktree-engine  +12 −3 · 2  ↑1", "■",
              "\uf07b folder \uf013 settings", "αβγ ЖЗИЙ", "سلام दुनिया", "中 文", "👩🏽‍💻 🇪🇸", "e\u0301 \u0301a", "\u200d\ufe0f", "\x00\n\r\t\x7f\u0080\u009f"]
    heights = [1, 7, 13, 16, 26, 39, 64, 97]
    widths = [0, 1, 5, 12, 24, 50, 80, 120, 160, 256, 8192]
    cases = [text_request(label.encode(), preferred, height, width)
             for label in labels for preferred in [0, 1, 2] for height in heights for width in [24, 80, 256]]
    long_labels = ["a" * 4096, "A V fi · " * 128, "\uf07b path/" * 64]
    cases += [text_request(label.encode(), preferred, 13, width) for label in long_labels for preferred in [0, 1, 2] for width in widths]
    generator = random.Random(0x7E1A)
    alphabet = ["A", "V", "fi", "ffi", "x", " ", "·", "λ", "Ж", "中", "⎇", "\uf07b", "\uf013", "é", "e\u0301", "👩🏽‍💻", "🇫🇷"]
    random_text_cases = 2000
    for _ in range(random_text_cases):
        label = "".join(generator.choices(alphabet, k=generator.randrange(1, 80))).encode()
        cases.append(text_request(label, generator.choice([0, 1, 2]), generator.choice(heights), generator.choice(widths)))
    cases += [text_request(label, 0, 13, 80) for label in [b"\x80", b"\xc0\xaf", b"\xf0\x9f", b"\xed\xa0\x80"]]
    transform_cases = 1000
    for _ in range(transform_cases):
        ink = [generator.uniform(-100, 100), generator.uniform(-100, 100), generator.uniform(.1, 400), generator.uniform(.1, 400)]
        cell = [generator.uniform(-100, 100), generator.uniform(-100, 100), generator.uniform(0, 200), generator.uniform(0, 200)]
        cases.append(struct.pack("<I8f", 1, *ink, *cell))
    for width, height in [(0, 20), (-1, 20), (20, 0), (float("inf"), 20), (float("nan"), 20)]:
        cases.append(struct.pack("<I8f", 1, 0, 0, width, height, 0, -10, 8, 16))
    return cases


def reference_command(root, build, work):
    includes = [Path(path) for path in include_paths(build)]
    freetype = next(path for path in includes if (path / "freetype/freetype.h").is_file())
    harfbuzz = next(path for path in includes if (path / "hb-ft.h").is_file())
    cache = (build / "CMakeCache.txt").read_text().splitlines()
    unicode_library = next(line.split("=", 1)[1] for line in cache if line.startswith("GHOSTTY_VT_LIBRARY:FILEPATH="))
    return ["zig", "build-exe", "-O", "ReleaseSafe", "-lc", "-lc++", str(build / "libgui-harfbuzz.a"), str(build / "libgui-freetype.a"), unicode_library,
            "--dep", "freetype", "--dep", "cellgrid", "--dep", "cellglyphs", "--dep", "gfx", "--dep", "assets", "--dep", "kitty_protocol", "--dep", "telar-core", "--dep", "unicode", f"-Mroot={work / 'probe.zig'}",
            "-I", str(freetype), "-I", str(harfbuzz), f"-Mfreetype={root / 'lib/freetype/root.zig'}",
            "--dep", "unicode", f"-Mcellgrid={root / 'lib/cellgrid/root.zig'}", "--dep", "gfx", f"-Mcellglyphs={root / 'lib/cellglyphs/root.zig'}",
            f"-Mgfx={root / 'lib/gfx/root.zig'}", f"-Massets={root / 'src/assets/assets.zig'}", f"-Mkitty_protocol={root / 'lib/kitty_protocol/root.zig'}", f"-Mtelar-core={work / 'core.zig'}", f"-Municode={work / 'unicode.zig'}", f"-femit-bin={work / 'original'}"]


def main():
    parser = argparse.ArgumentParser(description="Compare real original atlas measurement, resident font spans, fitted labels and fallback transforms")
    parser.add_argument("--build-dir", type=Path, default=Path(__file__).resolve().parents[1] / "out")
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--reference-build-dir", type=Path)
    options = parser.parse_args()
    root = Path(__file__).resolve().parents[3]
    build = options.build_dir.resolve()
    work = options.output_dir.resolve()
    work.mkdir(parents=True, exist_ok=False)
    (work / "src").symlink_to(root / "src", target_is_directory=True)
    (work / "core.zig").write_text('pub const Limit = @import("src/core/Limit.zig");\n')
    (work / "unicode.zig").write_text(unicode_facade)
    (work / "Canvas.zig").write_text(canvas_facade)
    (work / "Label.zig").write_text("text: []const u8,\n")
    (work / "TextFit.zig").write_bytes((root / "src/gui/widgets/TextFit.zig").read_bytes())
    atlas_source = (root / "src/gui/text/GlyphAtlas.zig").read_text()
    transform_start = atlas_source.index("const GlyphTransform = struct {")
    transform_end = atlas_source.index("\n};", transform_start) + len("\n};")
    transform = atlas_source[transform_start:transform_end]
    (work / "probe.zig").write_text(reference_probe.replace("__TRANSFORM__", transform))
    reference_build = options.reference_build_dir.resolve() if options.reference_build_dir else build
    command = reference_command(root, reference_build, work)
    subprocess.run(command, check=True, timeout=180)
    cases = requests()
    payload = b"".join(cases)
    (work / "input.bin").write_bytes(payload)
    digests = {}
    variants = ["JetBrainsMono-Regular.ttf", "IBMPlexSans-Regular.ttf", "SymbolsNerdFontMono-Regular.ttf"]
    for index, font in enumerate(variants):
        expected = subprocess.run([work / "original"], input=struct.pack("<I", index) + payload, capture_output=True, check=True, timeout=180).stdout
        actual = subprocess.run([build / "gui-font-cascade-probe", root / "assets", font], input=payload, capture_output=True, check=True, timeout=180).stdout
        (work / (str(index) + "-original.bin")).write_bytes(expected)
        (work / (str(index) + "-cpp.bin")).write_bytes(actual)
        if expected != actual:
            offset = next((offset for offset, pair in enumerate(zip(expected, actual)) if pair[0] != pair[1]), min(len(expected), len(actual)))
            raise RuntimeError(f"Cascade mismatch for {font} at output byte {offset}: original={len(expected)}, cpp={len(actual)}")
        digests[font] = dict(cases=len(cases), output_bytes=len(actual), output_sha256=hashlib.sha256(actual).hexdigest())
        print("Matched", len(cases), "cascade cases for", font, flush=True)
    sources = ["src/gui/text/GlyphAtlas.zig", "src/gui/text/FontSet.zig", "src/gui/text/FontRuns.zig", "src/gui/text/FontFace.zig", "src/gui/widgets/TextFit.zig", "lib/cellgrid/GraphemeIterator.zig", "lib/kitty_protocol/unicode_placeholder.zig",
               "services/gui-cpp/fonts/font_role.hpp", "services/gui-cpp/fonts/font_cascade.hpp", "services/gui-cpp/fonts/font_runs.hpp", "services/gui-cpp/fonts/text_layout.hpp", "services/gui-cpp/fonts/glyph_transform.hpp", "services/gui-cpp/fonts/face.cpp", "services/gui-cpp/tests/font_fixture.hpp", "services/gui-cpp/tools/font_cascade_probe.cpp", "services/gui-cpp/tools/check_font_cascade.py"]
    result = dict(cases=len(cases) * len(variants), variants=digests, input_sha256=hashlib.sha256(payload).hexdigest(), source_sha256={name:hashlib.sha256((root / name).read_bytes()).hexdigest() for name in sources}, reference_command=command,
                  scope="Unmodified original GlyphAtlas, FontSet, FontRuns and TextFit execute with actual bundled faces. The private GlyphTransform definition is copied unchanged. Canvas/Label adapt TextFit to the real atlas; Unicode uses the previously checked pinned Ghostty adapter. Covers nonprocedural text, three configured primary faces, resident fallback, missing glyphs, mixed-width fitting and transform arithmetic. Installed-font discovery, procedural cells, rasterization, native scheduling and comparative performance are outside this oracle.")
    (work / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result["variants"], indent=2))


if __name__ == "__main__":
    main()
