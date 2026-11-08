import argparse
import hashlib
import json
from pathlib import Path
import random
import shlex
import struct
import subprocess
import tempfile

from check_presentation import source_function


zig_probe = r'''
const std = @import("std");
const freetype = @import("freetype");
const FontFace = @import("gui/text/FontFace.zig");
const FontSize = @import("gui/text/FontSize.zig");
const ShapedRun = @import("gui/text/ShapedRun.zig");
const font_id = @import("gui/text/font_id.zig");
const FontVariation = @import("gui/native/FontVariation.zig").FontVariation;
extern "c" fn read(c_int, [*]u8, usize) isize;
extern "c" fn write(c_int, [*]const u8, usize) isize;
extern fn FT_GlyphSlot_Embolden(freetype.c.FT_GlyphSlot) void;
extern fn FT_GlyphSlot_Oblique(freetype.c.FT_GlyphSlot) void;
const FontRun = struct { text: []const u8, source: struct { font: font_id.Id = .sans } = .{}, preferred: font_id.Id = .sans, columns: u16 = 0, bold: bool = false, italic: bool = false };
const ShapingKey = struct { text: []const u8, face: font_id.Id, pixel_height: u16 };
const Pool = struct {
    face: FontFace,
    fn get(self: *Pool, _: font_id.Id) *FontFace { return &self.face; }
};
const Cache = struct {
    fn remember(_: *Cache, _: ShapingKey, _: ShapedRun) void {}
};
const Probe = struct {
    fonts: Pool,
    shaping_buffer: *freetype.c.hb_buffer_t,
    shaping_cache: Cache = .{},
    shape_calls: usize = 0,
    fn findShaped(_: *Probe, _: ShapingKey) ?ShapedRun { return null; }
    SHAPE_FUNCTION
};
const Bitmap = struct { width: u32, height: u32, left: i32, top: i32, buffer: [*c]u8, pitch: usize };
fn rasterize(font: *FontFace, index: u32, run: FontRun) !Bitmap {
    RASTER_FUNCTION
    return .{ .width = bitmap.width, .height = bitmap.rows, .left = glyph.*.bitmap_left, .top = glyph.*.bitmap_top, .buffer = bitmap.buffer, .pitch = @intCast(@abs(bitmap.pitch)) };
}
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
fn value(number: anytype) !void { try output(std.mem.asBytes(&number)); }
pub export fn telar_glyph_rasterizer_create(_: *const anyopaque) ?*anyopaque { return null; }
pub export fn telar_glyph_rasterizer_destroy(_: *anyopaque) void { @panic("Optical rasterization is outside this probe"); }
pub fn main() !void {
    const fonts = FONT_FILES;
    var font_index: u32 = 0;
    if (!readBytes(std.mem.asBytes(&font_index))) return error.MissingFont;
    var library: freetype.c.FT_Library = undefined;
    if (freetype.c.FT_Init_FreeType(&library) != 0) return error.FreeTypeInitFailed;
    defer _ = freetype.c.FT_Done_FreeType(library);
    var variation: FontVariation = .{};
    if (font_index == fonts.len - 1) {
        variation.count = 1;
        variation.tags[0] = 0x77647468;
        variation.values[0] = 200;
    }
    var probe: Probe = .{
        .fonts = .{ .face = try FontFace.init(library, .{ .font = fonts[font_index], .pixel_height = 13, .variation = variation }, &.{}) },
        .shaping_buffer = freetype.c.hb_buffer_create() orelse return error.BufferFailed,
    };
    defer probe.fonts.face.deinit();
    defer freetype.c.hb_buffer_destroy(probe.shaping_buffer);
    var request: [3]u32 = undefined;
    var text: [4096]u8 = undefined;
    while (readBytes(std.mem.asBytes(&request))) {
        if (request[0] > 4096 or request[1] > 3 or request[2] > text.len) return error.InvalidRequest;
        const label = text[0..request[2]];
        if (!readBytes(label)) return error.MissingText;
        const run: FontRun = .{ .text = label, .bold = request[1] & 1 != 0, .italic = request[1] & 2 != 0 };
        const height: u16 = @intCast(request[0]);
        const shaped = probe.shape(run, height) catch { try value(@as(i32, 2)); continue; };
        const size = try probe.fonts.face.sized(height);
        var advance: i64 = 0;
        for (shaped.positions) |position| { advance += position.x_advance; }
        try value([6]i32{ 1, size.ascender(), @intCast(size.lineHeight()), @intCast(size.maxAdvance()), @intCast(shaped.glyphs.len), FontSize.round26(advance) });
        try value(@as(u32, @intFromBool(shaped.rtl)));
        for (shaped.glyphs, shaped.positions) |info, position| {
            try value([6]i32{ @intCast(info.codepoint), @intCast(info.cluster), position.x_advance, position.y_advance, position.x_offset, position.y_offset });
            const bitmap = try rasterize(&probe.fonts.face, info.codepoint, run);
            try value([4]i32{ @intCast(bitmap.width), @intCast(bitmap.height), bitmap.left, bitmap.top });
            for (0..bitmap.height) |row| { try output(bitmap.buffer[row * bitmap.pitch ..][0..bitmap.width]); }
        }
    }
}
'''


def reference_source(root, paths):
    atlas = (root / "src/gui/text/GlyphAtlas.zig").read_text()
    shape = source_function(atlas, "fn shape(").replace("*GlyphAtlas", "*Probe")
    raster_start = atlas.index("    if (freetype.c.FT_Load_Glyph(font.face, index,")
    raster_end = atlas.index("    const origin = try self.packGlyph", raster_start)
    font_files = "[_][]const u8{" + ",".join(f'@embedFile("fonts/{index}.ttf")' for index in range(len(paths))) + "}"
    return zig_probe.replace("SHAPE_FUNCTION", shape).replace("RASTER_FUNCTION", atlas[raster_start:raster_end]).replace("FONT_FILES", font_files)


def requests():
    labels = ["Telar", "workspace · codex", "fi ffi fl office", "AVATAR To Wa", "llI1 0123456789", "Crème brûlée", "a\u0301 e\u0308 o\u0327", "\u05e9\u05dc\u05d5\u05dd", "\u0644\u0627\u0645", "\u4e2d\u6587", "\uea85 \uec20 \uf07b", "\U000f03ff", "\u2067abc\u2069", "a\x00b", " ⛶"]
    generator = random.Random(0x74657874)
    alphabet = "abcdefghijklmnopqrstuvwxyz AVWTo.,·éçßﬁﬃ\u0301\u0327\uea85"
    labels += ["".join(generator.choice(alphabet) for _ in range(generator.randrange(1, 65))) for _ in range(128)]
    heights = (11, 13, 14, 16, 17, 22, 26, 33)
    records = [(height, style, label.encode()) for height in heights for style in range(4) for label in labels]
    records += [(13, 0, invalid) for invalid in (b"\x80", b"\xc0\x80", b"\xe0\x80\x80", b"\xed\xa0\x80", b"\xf4\x90\x80\x80", b"\xf0\x9f", b"ok\xff")]
    return records


def include_paths(build):
    database = json.loads((build / "compile_commands.json").read_text())
    entry = next(entry for entry in database if entry["file"].endswith("/fonts/face.cpp"))
    arguments = entry.get("arguments") or shlex.split(entry["command"])
    paths = []
    for index, argument in enumerate(arguments):
        if argument in ("-I", "-isystem"):
            paths.append(arguments[index + 1])
        elif argument.startswith("-I"):
            paths.append(argument[2:])
    return paths


def output_counts(output, record_count):
    offset = 0
    glyphs = 0
    mask_bytes = 0
    rejected = 0
    for _ in range(record_count):
        state, = struct.unpack_from("<i", output, offset)
        if state == 2:
            rejected += 1
            offset += 4
            continue
        if state != 1:
            raise RuntimeError(f"Invalid output record state {state}")
        _, _, _, _, count, _ = struct.unpack_from("<6i", output, offset)
        offset += 28
        glyphs += count
        for _ in range(count):
            width, height, _, _ = struct.unpack_from("<4i", output, offset + 24)
            pixels = width * height
            mask_bytes += pixels
            offset += 40 + pixels
    if offset != len(output):
        raise RuntimeError("Unexpected shaping probe output length")
    return {"glyphs": glyphs, "mask_bytes": mask_bytes, "rejected": rejected}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--build-dir", type=Path, default=Path(__file__).resolve().parents[1] / "out")
    parser.add_argument("--compiler", default="clang++")
    parser.add_argument("--sanitizers", action="store_true")
    options = parser.parse_args()
    root = Path(__file__).resolve().parents[3]
    build = options.build_dir.resolve()
    includes = include_paths(build)
    freetype = next(path for path in includes if path.endswith("/include") and (Path(path) / "freetype/freetype.h").is_file())
    harfbuzz = next(path for path in includes if (Path(path) / "hb-ft.h").is_file())
    dependencies = [build / "libgui-harfbuzz.a", build / "libgui-freetype.a"]
    paths = [root / "assets" / name for name in ("IBMPlexSans-Regular.ttf", "IBMPlexSans-SemiBold.ttf", "JetBrainsMono-Regular.ttf", "SymbolsNerdFontMono-Regular.ttf")]
    paths += [root / "services/gui-cpp/tests/fixtures/metrics-variable.ttf"] * 2
    records = requests()
    payload = b"".join(struct.pack("<3I", height, style, len(text)) + text for height, style, text in records)
    with tempfile.TemporaryDirectory(prefix="telar-font-shaping-") as directory:
        work = Path(directory)
        (work / "fonts").mkdir()
        for index, path in enumerate(paths):
            (work / "fonts" / f"{index}.ttf").write_bytes(path.read_bytes())
        for relative in ("text/FontFace.zig", "text/FontSize.zig", "text/AtlasOptions.zig", "text/MacRasterizer.zig", "text/ShapedRun.zig", "text/font_id.zig", "native/FontVariation.zig", "native/GlyphRaster.zig"):
            destination = work / "gui" / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes((root / "src/gui" / relative).read_bytes())
        (work / "probe.zig").write_text(reference_source(root, paths))
        flags = ["-std=c++23", "-O2", "-ffp-contract=off", "-pthread"]
        if options.sanitizers:
            flags += ["-fsanitize=address,undefined", "-fno-omit-frame-pointer"]
        include_flags = [argument for path in includes for argument in ("-isystem", path)]
        face_source = root / "services/gui-cpp/fonts/face.cpp"
        implementation = [face_source, root / "services/gui-cpp/fonts/ligature_coverage.cpp"] if options.sanitizers else [build / "libgui-fonts.a"]
        subprocess.run([options.compiler, *flags, *include_flags, root / "services/gui-cpp/tools/font_shaping_probe.cpp", *implementation, *dependencies, "-o", work / "cpp"], check=True, timeout=180)
        subprocess.run(["zig", "build-exe", "-O", "ReleaseSafe", "-lc", "-lc++", *dependencies,
                        "--dep", "freetype", f"-Mroot={work / 'probe.zig'}", "-I", freetype, "-I", harfbuzz,
                        f"-Mfreetype={root / 'lib/freetype/root.zig'}", f"-femit-bin={work / 'zig'}"], check=True, timeout=180)
        digest = hashlib.sha256()
        counts = {"glyphs": 0, "mask_bytes": 0, "rejected": 0}
        for index, path in enumerate(paths):
            expected = subprocess.run([work / "zig"], input=struct.pack("<I", index) + payload, capture_output=True, check=True, timeout=60).stdout
            actual = subprocess.run([work / "cpp", path, "wide" if index == len(paths) - 1 else "regular"], input=payload, capture_output=True, check=True, timeout=60).stdout
            if actual != expected:
                offset = next((offset for offset, pair in enumerate(zip(actual, expected)) if pair[0] != pair[1]), min(len(actual), len(expected)))
                raise RuntimeError(f"Shaping/raster mismatch in {path.name}, variant {index}, output byte {offset}: C++ length {len(actual)}, Zig length {len(expected)}")
            digest.update(actual)
            for key, value in output_counts(actual, len(records)).items():
                counts[key] += value
            print(f"Matched {len(records):,} shaped runs and glyph bitmaps: {path.name}, variant {index}", flush=True)
        print(json.dumps({"runs": len(records) * len(paths), **counts, "input_sha256": hashlib.sha256(payload).hexdigest(), "output_sha256": digest.hexdigest(), "cpp_sanitizers": options.sanitizers, "dependencies_instrumented": False}))


if __name__ == "__main__":
    main()
