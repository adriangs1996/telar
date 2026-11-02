import argparse
import hashlib
import json
from pathlib import Path
import random
import struct
import subprocess

from check_font_cascade import reference_command
from check_font_shaping import source_function
from check_text_fit import unicode_facade


reference_probe = r'''
const std = @import("std");
const assets = @import("assets");
const cellgrid = @import("cellgrid");
const cellglyphs = @import("cellglyphs");
const freetype = @import("freetype");
const GlyphAtlas = @import("src/gui/text/GlyphAtlas.zig");
const FontSet = @import("src/gui/text/FontSet.zig");
const FontRun = @import("src/gui/text/FontRun.zig");
const ShapedRun = @import("src/gui/text/ShapedRun.zig");
const RowRuns = @import("src/gui/render/RowRuns.zig");
const font_id = @import("src/gui/text/font_id.zig");
const ShapingKey = struct { text: []const u8, face: font_id.Id, pixel_height: u16 };
const ColdCache = struct { fn remember(_: *ColdCache, _: ShapingKey, _: ShapedRun) void {} };
const Probe = struct {
    fonts: *FontSet,
    shaping_buffer: *freetype.c.hb_buffer_t,
    shaping_cache: ColdCache = .{},
    shape_calls: usize = 0,
    fn findShaped(_: *Probe, _: ShapingKey) ?ShapedRun { return null; }
    __SHAPE__
};
extern "c" fn read(c_int, [*]u8, usize) isize;
extern "c" fn write(c_int, [*]const u8, usize) isize;
pub export fn telar_glyph_rasterizer_create(_: *const anyopaque) ?*anyopaque { return null; }
pub export fn telar_glyph_rasterizer_destroy(_: *anyopaque) void { @panic("Optical rendering is outside the row probe"); }
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
fn color(raw: u32) cellgrid.Color {
    return switch (raw >> 24) { 0 => .default, 1 => .indexed(@truncate(raw)), 2 => .rgb(.{ @truncate(raw >> 16), @truncate(raw >> 8), @truncate(raw) }), else => unreachable };
}
fn readCell() !cellgrid.Cell {
    const fields = try input([5]u32);
    const length = try input(u16);
    var cell: cellgrid.Cell = .{};
    if (length > cell.bytes.len or !readBytes(cell.bytes[0..length])) return error.InvalidCell;
    cell.len = @intCast(length);
    cell.width = @intCast(fields[4]);
    cell.style = .{ .flags = @bitCast(@as(u16, @intCast(fields[0]))), .fg = color(fields[1]), .bg = color(fields[2]), .underline_color = color(fields[3]) };
    return cell;
}
fn emitGlyphs(run: ShapedRun, offset: i32) !void {
    try value(@as(u32, @intCast(run.glyphs.len)));
    for (run.glyphs, run.positions) |glyph, position| {
        try value([6]i32{ @intCast(glyph.codepoint), position.x_advance, position.y_advance, position.x_offset, position.y_offset, offset });
    }
}
fn alone(probe: *Probe, cell: cellgrid.Cell, height: u16, offset: i32) !void {
    const text = cell.text();
    if (cell.width == 0 or cell.style.flags.invisible or cellglyphs.Braille.parse(text) != null or cellglyphs.BoxDrawing.parse(text) != null or cellglyphs.BlockElement.parse(text) != null or probe.fonts.source(text, .primary) != .primary) {
        try value(@as(u32, 0));
        return;
    }
    try emitGlyphs(try probe.shape(.{ .text = text, .source = .{ .font = .primary }, .columns = @max(1, cell.width) }, height), offset);
}
fn together(probe: *Probe, cells: []const cellgrid.Cell, fields: [5]u32, start: usize) !bool {
    var bytes: [RowRuns.max_bytes]u8 = undefined;
    var ends: [RowRuns.max_cells]u32 = undefined;
    var length: usize = 0;
    for (cells, 0..) |cell, index| {
        @memcpy(bytes[length..][0..cell.len], cell.text());
        length += cell.len;
        ends[index] = @intCast(length);
    }
    const shaped = try probe.shape(.{ .text = bytes[0..length], .source = .{ .font = .primary }, .columns = @intCast(cells.len) }, @intCast(fields[0]));
    if (!shaped.ordered() or shaped.glyphs.len == 0 or shaped.glyphs.len > RowRuns.max_glyphs) return false;
    var rest = shaped;
    for (cells, 0..) |_, index| {
        const parts = rest.split(ends[index]);
        rest = parts[1];
        try emitGlyphs(parts[0], @intCast((start + index) * fields[1]));
    }
    return true;
}
pub fn main() !void {
    const font_index = try input(u32);
    const fonts = [_][]const u8{ assets.jetbrains_mono, assets.plex_sans, assets.nerd_symbols };
    var atlas = try GlyphAtlas.init(std.heap.page_allocator, .{ .font = fonts[font_index], .pixel_height = 13, .side = GlyphAtlas.max_side });
    defer atlas.deinit();
    var probe: Probe = .{ .fonts = &atlas.fonts, .shaping_buffer = atlas.shaping_buffer };
    var runs = RowRuns.init(std.heap.page_allocator);
    defer runs.deinit();
    while (true) {
        var count: u32 = 0;
        if (!readBytes(std.mem.asBytes(&count))) break;
        const fields = try input([5]u32);
        const cells = try std.heap.page_allocator.alloc(cellgrid.Cell, count);
        defer std.heap.page_allocator.free(cells);
        for (cells) |*cell| cell.* = try readCell();
        const coverage = atlas.ligatures();
        try value([2]u32{ coverage.reach, @intFromBool(coverage.joins()) });
        try runs.reserve(@intCast(count));
        runs.clear();
        for (cells, 0..) |original, column| {
            try value(@as(u32, @intFromEnum(coverage.role(original.text()))));
            var cell = original;
            if (fields[3] != std.math.maxInt(u32) and column >= @min(fields[3], fields[4]) and column <= @max(fields[3], fields[4])) cell.style.flags.inverse = !cell.style.flags.inverse;
            runs.append(coverage, &cell, fields[2] == column);
        }
        runs.close(coverage.reach);
        var column: u16 = 0;
        while (column < count) {
            const run = runs.at(column);
            try value([2]u32{ run.len, @intFromBool(run.together) });
            column += run.len;
        }
        try value(@as(u32, 0));
        column = 0;
        while (column < count) {
            const run = runs.at(column);
            if (!run.together or !try together(&probe, cells[column..][0..run.len], fields, column)) {
                for (cells[column..][0..run.len], column..) |cell, index| try alone(&probe, cell, @intCast(fields[0]), @intCast(index * fields[1]));
            }
            column += run.len;
        }
    }
}
'''


def encode(cells, height=15, width=9, cursor=None, selection=None):
    absent = 0xffffffff
    first, last = selection if selection else (absent, absent)
    frame = struct.pack('<6I', len(cells), height, width, cursor if cursor is not None else absent, first, last)
    for text, flags, foreground, background, underline, columns in cells:
        data = text.encode()
        frame += struct.pack('<5IH', flags, foreground, background, underline, columns, len(data)) + data
    return frame


def corpus():
    plain = lambda text: [(character, 0, 0, 0, 0, 1) for character in text]
    cases = [encode(plain(text), cursor=cursor, selection=selection)
             for text in ['', 'A -> B', '== === != !== -> --> => <=>', 'fi fl st office', 'i' * 129, '=' * 127, '=' * 128, '=' * 129, '=' * 256, ' ' * 130]
             for cursor in [None, 0, 2, 6] for selection in [None, (1, 4)]]
    generator = random.Random(0xC311)
    alphabet = ['a', 'A', 'V', 'W', 'f', 'i', 'l', 's', 't', ' ', '=', '-', '>', '<', '!', ':', '.', 'é', 'e\u0301', 'λ', 'Ж', '中', '\uf07b', '\u2500', '\u2588', '\u28ff', 'س', 'ש']
    for _ in range(2400):
        cells = []
        for _ in range(generator.randrange(1, 180)):
            text = generator.choice(alphabet)
            columns = 2 if text == '中' else 1
            flags = generator.choice([0] * 12 + [1, 2, 4, 16, 32, 64, 128, 256, 512, 768, 1024, 1280])
            foreground = generator.choice([0] * 12 + [0x1000001, 0x2001040])
            background = generator.choice([0] * 8 + [0x1000002, 0x2002040])
            underline = generator.choice([0] * 12 + [0x1000003])
            cells.append((text, flags, foreground, background, underline, columns))
            if columns == 2:
                cells.append(('', flags, foreground, background, underline, 0))
        cursor = generator.choice([None, generator.randrange(len(cells))])
        selection = (generator.randrange(len(cells)), generator.randrange(len(cells))) if generator.randrange(3) == 0 else None
        cases.append(encode(cells, generator.choice([7, 13, 15, 26, 39]), generator.choice([1, 3, 9, 17, 33, 200]), cursor, selection))
    cases += [encode(plain('=' * size)) for size in [0xffff, 0xfffe]]
    return cases


def main():
    parser = argparse.ArgumentParser(description='Compare font ligature roles, terminal run boundaries and primary glyph positions against original Zig components')
    parser.add_argument('--build-dir', type=Path, default=Path(__file__).resolve().parents[1] / 'out')
    parser.add_argument('--output-dir', type=Path, required=True)
    parser.add_argument('--reference-build-dir', type=Path)
    options = parser.parse_args()
    root = Path(__file__).resolve().parents[3]
    build = options.build_dir.resolve()
    work = options.output_dir.resolve()
    work.mkdir(parents=True, exist_ok=False)
    (work / 'src').symlink_to(root / 'src', target_is_directory=True)
    (work / 'core.zig').write_text('pub const Limit = @import("src/core/Limit.zig");\n')
    (work / 'unicode.zig').write_text(unicode_facade)
    atlas = (root / 'src/gui/text/GlyphAtlas.zig').read_text()
    shape = source_function(atlas, 'fn shape(').replace('*GlyphAtlas', '*Probe')
    (work / 'probe.zig').write_text(reference_probe.replace('__SHAPE__', shape))
    command = reference_command(root, options.reference_build_dir.resolve() if options.reference_build_dir else build, work)
    subprocess.run(command, check=True, timeout=180)
    cases = corpus()
    payload = b''.join(cases)
    (work / 'input.bin').write_bytes(payload)
    variants = {}
    for index, font in enumerate(['JetBrainsMono-Regular.ttf', 'IBMPlexSans-Regular.ttf', 'SymbolsNerdFontMono-Regular.ttf']):
        expected = subprocess.run([work / 'original'], input=struct.pack('<I', index) + payload, capture_output=True, check=True, timeout=180).stdout
        actual = subprocess.run([build / 'gui-row-text-probe', root / 'src/assets', font], input=payload, capture_output=True, check=True, timeout=180).stdout
        (work / f'{index}-original.bin').write_bytes(expected)
        (work / f'{index}-cpp.bin').write_bytes(actual)
        if expected != actual:
            offset = next((i for i, pair in enumerate(zip(expected, actual)) if pair[0] != pair[1]), min(len(expected), len(actual)))
            raise RuntimeError(f'Row text mismatch for {font} at byte {offset}: original={len(expected)}, cpp={len(actual)}')
        variants[font] = dict(cases=len(cases), output_bytes=len(actual), output_sha256=hashlib.sha256(actual).hexdigest())
        print('Matched', len(cases), 'row cases for', font, flush=True)
    sources = ['src/gui/text/LigatureCoverage.zig', 'src/gui/render/RowRuns.zig', 'src/gui/text/ShapedRun.zig', 'src/gui/text/GlyphAtlas.zig', 'services/gui-cpp/fonts/ligature_coverage.cpp', 'services/gui-cpp/fonts/ligature_coverage.hpp', 'services/gui-cpp/fonts/ligature_role.hpp', 'services/gui-cpp/terminal/text_runs.hpp', 'services/gui-cpp/fonts/row_text_layout.hpp', 'services/gui-cpp/tools/row_text_probe.cpp', 'services/gui-cpp/tools/check_row_text.py']
    result = dict(cases=len(cases) * len(variants), variants=variants, input_sha256=hashlib.sha256(payload).hexdigest(), source_sha256={name:hashlib.sha256((root / name).read_bytes()).hexdigest() for name in sources}, reference_command=command, scope='Unmodified original LigatureCoverage, RowRuns and ShapedRun execute with real bundled faces. The original cold GlyphAtlas.shape body is copied unchanged except its owner type, with a cache-miss adapter. Covers role/context reach, cursor/ink/selection boundaries, long runs, wide/spacer/procedural cells and primary glyph IDs/positions placed per grid cell. Fallback glyph positions, rasterization, GPU state, installed discovery, optical rendering and comparative performance are outside this oracle.')
    (work / 'result.json').write_text(json.dumps(result, indent=2)+'\n')


if __name__ == '__main__':
    main()
