import argparse
import hashlib
import json
from pathlib import Path
import random
import struct
import subprocess

from check_font_shaping import include_paths
from check_presentation import source_function


canvas_facade = r'''
const std = @import("std");
const freetype = @import("freetype");
const FontFace = @import("gui/text/FontFace.zig");
const FontSize = @import("gui/text/FontSize.zig");
const ShapedRun = @import("gui/text/ShapedRun.zig");
const font_id = @import("gui/text/font_id.zig");
const Label = @import("Label.zig");
const Canvas = @This();
pub const FontRun = struct { text: []const u8, source: struct { font: font_id.Id = .sans } = .{}, preferred: font_id.Id = .sans, columns: u16 = 0, bold: bool = false, italic: bool = false };
const ShapingKey = struct { text: []const u8, face: font_id.Id, pixel_height: u16 };
pub const Pool = struct {
    face: FontFace,
    pub fn get(self: *Pool, _: font_id.Id) *FontFace { return &self.face; }
};
const Cache = struct {
    fn remember(_: *Cache, _: ShapingKey, _: ShapedRun) void {}
};
fonts: Pool,
shaping_buffer: *freetype.c.hb_buffer_t,
shaping_cache: Cache = .{},
shape_calls: usize = 0,
pixel_height: u16 = 13,
fn findShaped(_: *Canvas, _: ShapingKey) ?ShapedRun { return null; }
SHAPE_FUNCTION
pub fn measure(self: *Canvas, label: Label) !f32 {
    if (label.text.len == 0) return 0;
    const run = try self.shape(.{ .text = label.text }, self.pixel_height);
    var advance: i64 = 0;
    for (run.positions) |position| advance += position.x_advance;
    return @floatFromInt(FontSize.round26(advance));
}
'''


unicode_facade = r'''
extern fn ghostty_unicode_grapheme_width([*]const u32, usize, ?*u8) usize;
pub fn graphemeWidth(codepoints: []const u21) struct { len: usize, width: u8 } {
    var widened: [16]u32 = undefined;
    for (codepoints, 0..) |codepoint, index| widened[index] = codepoint;
    var width: u8 = 0;
    const length = ghostty_unicode_grapheme_width(&widened, codepoints.len, &width);
    return .{ .len = length, .width = width };
}
'''


zig_probe = r'''
const std = @import("std");
const freetype = @import("freetype");
const FontFace = @import("gui/text/FontFace.zig");
const Canvas = @import("Canvas.zig");
const TextFit = @import("TextFit.zig");
const GraphemeIterator = @import("cellgrid").GraphemeIterator;
extern "c" fn read(c_int, [*]u8, usize) isize;
extern "c" fn write(c_int, [*]const u8, usize) isize;
fn readBytes(bytes: []u8) bool {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = read(0, bytes[offset..].ptr, bytes.len - offset);
        if (count <= 0) return false;
        offset += @intCast(count);
    }
    return true;
}
fn output(bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = write(1, bytes[offset..].ptr, bytes.len - offset);
        if (count <= 0) return error.WriteFailed;
        offset += @intCast(count);
    }
}
fn text(bytes: []const u8) !void {
    const length: u32 = @intCast(bytes.len);
    try output(std.mem.asBytes(&length));
    try output(bytes);
}
pub export fn telar_glyph_rasterizer_create(_: *const anyopaque) ?*anyopaque { return null; }
pub export fn telar_glyph_rasterizer_destroy(_: *anyopaque) void { @panic("Optical rasterization is outside this probe"); }
pub fn main() !void {
    const fonts = FONT_FILES;
    var font_index: u32 = 0;
    if (!readBytes(std.mem.asBytes(&font_index))) return error.MissingFont;
    var library: freetype.c.FT_Library = undefined;
    if (freetype.c.FT_Init_FreeType(&library) != 0) return error.FreeTypeInitFailed;
    defer _ = freetype.c.FT_Done_FreeType(library);
    var canvas: Canvas = .{
        .fonts = .{ .face = try FontFace.init(library, .{ .font = fonts[font_index], .pixel_height = 13 }, &.{}) },
        .shaping_buffer = freetype.c.hb_buffer_create() orelse return error.BufferFailed,
    };
    defer canvas.fonts.face.deinit();
    defer freetype.c.hb_buffer_destroy(canvas.shaping_buffer);
    var request: [4]u32 = undefined;
    var bytes: [4096]u8 = undefined;
    while (readBytes(std.mem.asBytes(&request))) {
        if (request[0] > 1 or request[1] == 0 or request[1] > 4096 or request[3] > bytes.len) return error.InvalidRequest;
        const label = bytes[0..request[3]];
        if (!readBytes(label)) return error.MissingText;
        if (request[0] == 1) {
            var cursor: GraphemeIterator = .{ .bytes = label };
            while (cursor.next()) |cluster| try text(cluster.bytes);
            try text("");
        } else {
            canvas.pixel_height = @intCast(request[1]);
            const fit: TextFit = .{ .canvas = &canvas, .width = @bitCast(request[2]) };
            var buffer: [TextFit.max_bytes]u8 = undefined;
            try text(try fit.fit(.{ .text = label }, &buffer));
        }
    }
}
'''


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def records():
    labels = [
        "", "Telar", "Adrians-MacBook-Pro.local · telar-gui-render-reference",
        "workspace · codex", "fi ffi fl office", "AVATAR To Wa", "Crème brûlée",
        "a\u0301 e\u0308 o\u0327", "שלום", "لام", "中文", "🇪🇸", "👩🏽‍💻",
        "\uea85 \uec20 \uf07b", "a\x00b", "a" + "\u0301" * 35 + "Z",
        "i" * 1024, "W" * 512, "👩🏽‍💻" * 64,
    ]
    generator = random.Random(0x666974)
    alphabet = "abcdefghijklmnopqrstuvwxyz AVWTo.,·éçßﬁﬃ\u0301\u0327中"
    labels += ["".join(generator.choice(alphabet) for _ in range(generator.randrange(1, 100))) for _ in range(64)]
    heights = (11, 13, 14, 16, 17, 22, 26, 33)
    widths = (-1, 0, 0.5, 1, 4, 10, 15, 31.5, 70, 153.75, 154, 237, 500, 1000, 5000, 100000)
    requests = [(0, height, width, label.encode()) for height in heights for width in widths for label in labels]
    clusters = labels + ["\x00\n\x1b\x7f\u0080\u009f", "\r\n", "🇪🇸🇫🇷🇩", "\u0301\u0301a", "\u200d👩🏽‍💻"]
    requests += [(1, 13, 0, label.encode()) for label in clusters]
    return requests


def reference_files(root, work, fonts):
    files = {
        "TextFit.zig": "src/gui/widgets/TextFit.zig",
        "GraphemeIterator.zig": "lib/cellgrid/GraphemeIterator.zig",
        "Cluster.zig": "lib/cellgrid/Cluster.zig",
        "text.zig": "lib/cellgrid/text.zig",
    }
    font_files = ["text/FontFace.zig", "text/FontSize.zig", "text/AtlasOptions.zig", "text/MacRasterizer.zig", "text/ShapedRun.zig", "text/font_id.zig", "native/FontVariation.zig", "native/GlyphRaster.zig"]
    files.update({"gui/" + name: "src/gui/" + name for name in font_files})
    for destination, source in files.items():
        path = work / destination
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes((root / source).read_bytes())
    shape = source_function((root / "src/gui/text/GlyphAtlas.zig").read_text(), "fn shape(")
    shape = shape.replace("*GlyphAtlas", "*Canvas")
    (work / "Canvas.zig").write_text(canvas_facade.replace("SHAPE_FUNCTION", shape))
    (work / "Label.zig").write_text("text: []const u8,\n")
    (work / "cellgrid.zig").write_text('pub const GraphemeIterator = @import("GraphemeIterator.zig");\n')
    (work / "unicode.zig").write_text(unicode_facade)
    (work / "fonts").mkdir(exist_ok=True)
    for index, path in enumerate(fonts):
        (work / "fonts" / f"{index}.ttf").write_bytes(path.read_bytes())
    embedded = "[_][]const u8{" + ",".join(f'@embedFile("fonts/{index}.ttf")' for index in range(len(fonts))) + "}"
    (work / "probe.zig").write_text(zig_probe.replace("FONT_FILES", embedded))
    return list(files.values()) + ["src/gui/text/GlyphAtlas.zig", "lib/unicode/root.zig"]


def reference_command(root, build, work):
    includes = [Path(path) for path in include_paths(build)]
    freetype = next(path for path in includes if (path / "freetype/freetype.h").is_file())
    harfbuzz = next(path for path in includes if (path / "hb-ft.h").is_file())
    cache = (build / "CMakeCache.txt").read_text().splitlines()
    unicode_library = next(line.split("=", 1)[1] for line in cache if line.startswith("GHOSTTY_VT_LIBRARY:FILEPATH="))
    return [
        "zig", "build-exe", "-O", "ReleaseSafe", "-lc", "-lc++",
        str(build / "libgui-harfbuzz.a"), str(build / "libgui-freetype.a"), unicode_library,
        "--dep", "freetype", "--dep", "cellgrid", "--dep", "unicode", f"-Mroot={work / 'probe.zig'}",
        "-I", str(freetype), "-I", str(harfbuzz), f"-Mfreetype={root / 'lib/freetype/root.zig'}",
        "--dep", "unicode", f"-Mcellgrid={work / 'cellgrid.zig'}", f"-Municode={work / 'unicode.zig'}",
        f"-femit-bin={work / 'zig'}",
    ]


def verify_rejections(binary, font):
    invalid_scalars = (b"\xc0\x80", b"\xe0\x80\x80", b"\xed\xa0\x80", b"\xf4\x90\x80\x80")
    cases = [(1, 13, 0, invalid, "Invalid or overlong UTF-8 scalar") for invalid in invalid_scalars]
    cases += [(1, 13, 0, b"\x80", "Invalid UTF-8 leading byte"), (1, 13, 0, b"\xf0\x9f", "InvalidGraphemeUtf8")]
    cases += [(0, 13, width, b"label", "InvalidTextFitRequest") for width in (float("nan"), float("inf"))]
    for kind, height, width, text, error in cases:
        payload = struct.pack("<IIfI", kind, height, width, len(text)) + text
        result = subprocess.run([binary, font], input=payload, capture_output=True, timeout=10)
        if result.returncode != 1 or result.stdout or result.stderr != error.encode():
            raise RuntimeError(f"Expected rejected text-fit input, got {result.returncode}: {result.stderr!r}")
    return len(cases)


def run(options):
    root = Path(__file__).resolve().parents[3]
    build = options.build_dir.resolve()
    reference_build = (options.reference_build_dir or build).resolve()
    work = options.output_dir.resolve()
    work.mkdir(parents=True, exist_ok=True)
    fonts = [root / "src/assets" / name for name in ("IBMPlexSans-Regular.ttf", "IBMPlexSans-SemiBold.ttf", "SymbolsNerdFontMono-Regular.ttf")]
    sources = reference_files(root, work, fonts)
    command = reference_command(root, reference_build, work)
    subprocess.run(command, check=True, timeout=180)
    requests = records()
    payload = b"".join(struct.pack("<IIfI", kind, height, width, len(text)) + text for kind, height, width, text in requests)
    binary = build / "gui-text-fit-probe"
    digest = hashlib.sha256()
    for index, font in enumerate(fonts):
        expected = subprocess.run([work / "zig"], input=struct.pack("<I", index) + payload, capture_output=True, check=True, timeout=120).stdout
        actual = subprocess.run([binary, font], input=payload, capture_output=True, check=True, timeout=120).stdout
        if actual != expected:
            offset = next((offset for offset, pair in enumerate(zip(actual, expected)) if pair[0] != pair[1]), min(len(actual), len(expected)))
            raise RuntimeError(f"Text-fit mismatch in {font.name}, byte {offset}: C++ length {len(actual)}, Zig length {len(expected)}")
        digest.update(actual)
        print(f"Matched {len(requests):,} fitted-label/segmentation records: {font.name}", flush=True)
    rejections = verify_rejections(binary, fonts[0])
    sources += ["services/gui-cpp/text/text_fit.hpp", "services/gui-cpp/text/grapheme_cursor.hpp", "services/gui-cpp/tools/text_fit_probe.cpp", "services/gui-cpp/tools/check_text_fit.py"]
    result = {
        "scope": "Original TextFit and GraphemeIterator functions, original HarfBuzz shaping with one selected face; no full font fallback or window parity claim.",
        "reference_adaptation": "Canvas/Label are isolated facades. Canvas uses the original shaping function and fixed-point advance. Unicode forwards to the pinned Ghostty C grapheme API. TextFit and GraphemeIterator source bytes are unchanged.",
        "records": len(requests) * len(fonts),
        "fit_records": sum(kind == 0 for kind, _, _, _ in requests) * len(fonts),
        "segmentation_records": sum(kind == 1 for kind, _, _, _ in requests) * len(fonts),
        "rejected_invalid_inputs": rejections,
        "input_sha256": hashlib.sha256(payload).hexdigest(), "output_sha256": digest.hexdigest(),
        "source_sha256": {path: sha(root / path) for path in sources},
        "font_sha256": {path.name: sha(path) for path in fonts},
        "cpp_binary_sha256": sha(binary), "zig_binary_sha256": sha(work / "zig"),
        "generated_reference_sha256": {str(path.relative_to(work)): sha(path) for path in sorted(work.rglob("*.zig"))},
        "zig_command": command,
    }
    (work / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--build-dir", type=Path, default=Path("services/gui-cpp/out"))
    parser.add_argument("--reference-build-dir", type=Path)
    parser.add_argument("--output-dir", type=Path, required=True)
    run(parser.parse_args())


if __name__ == "__main__":
    main()
