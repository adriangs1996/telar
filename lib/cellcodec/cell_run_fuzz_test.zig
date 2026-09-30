//! Native fuzzing of `cellcodec` cell runs, the payload of every frame span.
//!
//! This root imports `cellcodec` as a module and runs only through
//! `zig build test-fuzz-frames-cells`; no suite imports it. One target reads
//! arbitrary bytes through `CellReader` beside a reference reader written
//! from the format's description. The other generates cells, encodes them
//! through both of `encode`'s paths, measures them and decodes them again.

const std = @import("std");
const bytecodec = @import("bytecodec");
const cellcodec = @import("cellcodec");
const cellgrid = @import("cellgrid");
const Cell = cellgrid.Cell;
const CellReader = cellcodec.CellReader;
const Color = cellgrid.cell_support.Color;
const Decoder = bytecodec.Decoder;
const Encoder = bytecodec.Encoder;
const Smith = std.testing.Smith;
const Style = cellgrid.Style;

/// The longest run either target reads or writes.
const max_fuzzed_cells = 64;
const payload_capacity = max_fuzzed_cells * cellcodec.max_cell_size;
/// Bytes a generated run is written after, as a span header precedes a run
/// inside a frame.
const max_prefix = 12;
const unlimited = std.math.maxInt(usize);

// The format as `cell_run.zig` describes it, restated so the reference
// reader shares no code with the decoder under test.
const text_length_mask: u8 = 0x1f;
const width_shift = 5;
const width_mask: u8 = 0x3;
const max_width = 2;
const attribute_bits: u16 = 0x00ff;
const underline_shift = 8;
const underline_mask: u16 = 0x7;
const reserved_flag_bits: u16 = 0xf800;
const first_reserved_flag_bit = 11;
const rgb_channels = 3;

const CellRunError = error{ Truncated, TrailingBytes, InvalidCell, InvalidStyle, InvalidColor };

/// A cell the reference reader accepted, and whether its header repeated
/// the previous style, the one encoding `encode` never writes.
const ReferenceCell = struct {
    cell: Cell,
    redundant_style: bool,
};

/// Reads a run the way the format describes it: header, style when the
/// header says it changed, text, then the cell's own rules, and nothing
/// after the last promised cell.
const ReferenceReader = struct {
    decoder: Decoder,
    remaining: u32,
    style: ?Style = null,

    fn next(self: *ReferenceReader) CellRunError!?ReferenceCell {
        if (self.remaining == 0) {
            return null;
        }

        self.remaining -= 1;
        const header = try self.decoder.readByte();
        const length = header & text_length_mask;
        const width = (header >> width_shift) & width_mask;
        const style_changed = header & cellcodec.style_changed_bit != 0;
        if (!style_changed and self.style == null) {
            return error.InvalidCell;
        }

        const style = if (style_changed) try readStyle(&self.decoder) else self.style.?;
        if (length > Cell.max_bytes) {
            return error.InvalidCell;
        }

        const text = try self.decoder.readBytes(length);
        if (width > max_width or (width == 0) != (length == 0)) {
            return error.InvalidCell;
        }

        const redundant_style = style_changed and self.style != null and self.style.?.eql(style);
        self.style = style;
        if (self.remaining == 0) {
            try self.decoder.ensureEnd();
        }

        return .{
            .cell = canonicalCell(text, width, style),
            .redundant_style = redundant_style,
        };
    }
};

fn readStyle(decoder: *Decoder) CellRunError!Style {
    const flags = try decoder.readInt(u16);
    if (flags & reserved_flag_bits != 0 or (flags >> underline_shift) & underline_mask > @intFromEnum(Style.Underline.dashed)) {
        return error.InvalidStyle;
    }

    const fg = try readColor(decoder);
    const bg = try readColor(decoder);
    const underline_color = try readColor(decoder);
    return .{
        .flags = @bitCast(flags),
        .fg = fg,
        .bg = bg,
        .underline_color = underline_color,
    };
}

fn readColor(decoder: *Decoder) CellRunError!Color {
    return switch (try decoder.readByte()) {
        @intFromEnum(Color.Kind.default) => .default,
        @intFromEnum(Color.Kind.indexed) => .indexed(try decoder.readByte()),
        @intFromEnum(Color.Kind.rgb) => .rgb((try decoder.readBytes(rgb_channels))[0..rgb_channels].*),
        else => error.InvalidColor,
    };
}

/// The one representation `Cell.eqlPublic` expects from the wire decoder:
/// default bytes after the text and zero in every channel a color's kind
/// does not use.
fn canonicalCell(text: []const u8, width: u8, style: Style) Cell {
    var cell: Cell = .{
        .len = @intCast(text.len),
        .width = width,
        .style = .{
            .flags = style.flags,
            .fg = canonicalColor(style.fg),
            .bg = canonicalColor(style.bg),
            .underline_color = canonicalColor(style.underline_color),
        },
    };
    @memcpy(cell.bytes[0..text.len], text);
    return cell;
}

fn canonicalColor(color: Color) Color {
    return switch (color.kind) {
        .default => .default,
        .indexed => .indexed(color.value[0]),
        .rgb => .rgb(color.value),
    };
}

/// What a generated cell decodes to: its text, width, flags and the
/// channels its colors use. Bytes past the text and unused channels are
/// not compared.
fn decodedForm(cell: Cell) Cell {
    return canonicalCell(cell.bytes[0..cell.len], cell.width, cell.style);
}

fn colorSize(color: Color) usize {
    const channels: usize = switch (color.kind) {
        .default => 0,
        .indexed => 1,
        .rgb => rgb_channels,
    };
    return @sizeOf(Color.Kind) + channels;
}

fn styleSize(style: Style) usize {
    return @sizeOf(u16) + colorSize(style.fg) + colorSize(style.bg) + colorSize(style.underline_color);
}

/// The size `encodedCellsSize` owes a run: a header and the text per cell,
/// and a style wherever it differs from the one before.
fn referenceRunSize(cells: []const Cell, previous_style: ?Style) usize {
    var size: usize = 0;
    var style = previous_style;
    for (cells) |cell| {
        const style_changed = style == null or !style.?.eql(cell.style);
        size += cellcodec.cell_header_size + cell.len + if (style_changed) styleSize(cell.style) else 0;
        style = cell.style;
    }

    return size;
}

/// A payload the decoding target starts from, the cells it promises and the
/// first error reading them owes; a null outcome reads every cell.
const CellRunSeed = struct {
    count: u32,
    payload: []const u8,
    outcome: ?CellRunError,
};

fn cellHeader(comptime length: u8, comptime width: u8, comptime style_changed: bool) u8 {
    return length | (width << width_shift) | if (style_changed) cellcodec.style_changed_bit else 0;
}

fn flagBytes(comptime bits: u16) [@sizeOf(u16)]u8 {
    var bytes: [@sizeOf(u16)]u8 = undefined;
    std.mem.writeInt(u16, &bytes, bits, .little);
    return bytes;
}

const default_colors = [_]u8{@intFromEnum(Color.Kind.default)} ** 3;
const default_style = flagBytes(0) ++ default_colors;
const accent_flags: Style.Flags = .{
    .bold = true,
    .underline = .curly,
};
/// Bold with a curly underline, an RGB foreground and an indexed background.
const accent_style = flagBytes(@bitCast(accent_flags)) ++ [_]u8{ @intFromEnum(Color.Kind.rgb), 1, 2, 3, @intFromEnum(Color.Kind.indexed), 4, @intFromEnum(Color.Kind.default) };
const reserved_flag = flagBytes(1 << first_reserved_flag_bit);
const unknown_underline = flagBytes(@as(u16, @intFromEnum(Style.Underline.dashed) + 1) << underline_shift);
const default_cell = [_]u8{cellHeader(1, 1, true)} ++ default_style ++ " ".*;

const cell_run_seeds = [_]CellRunSeed{
    .{
        .count = 1,
        .payload = &default_cell,
        .outcome = null,
    },
    .{
        .count = 2,
        .payload = &(default_cell ++ [_]u8{ cellHeader(1, 1, false), 'a' }),
        .outcome = null,
    },
    .{
        .count = 2,
        .payload = &(default_cell ++ [_]u8{cellHeader(1, 1, true)} ++ accent_style ++ "b".*),
        .outcome = null,
    },
    .{
        .count = 2,
        .payload = &([_]u8{cellHeader(4, 2, true)} ++ accent_style ++ "\u{1F600}".* ++ [_]u8{cellHeader(0, 0, false)}),
        .outcome = null,
    },
    .{
        .count = 1,
        .payload = &([_]u8{cellHeader(Cell.max_bytes, 1, true)} ++ default_style ++ "abcdefghijklmnop".*),
        .outcome = null,
    },
    // A style repeated although it did not change: valid, but `encode`
    // writes the same cells shorter.
    .{
        .count = 2,
        .payload = &(default_cell ++ [_]u8{cellHeader(1, 1, true)} ++ default_style ++ "c".*),
        .outcome = null,
    },
    // No promised cell: the reader returns null without reading the bytes.
    .{
        .count = 0,
        .payload = &default_cell,
        .outcome = null,
    },
    .{
        .count = 1,
        .payload = &[_]u8{ cellHeader(1, 1, false), ' ' },
        .outcome = error.InvalidCell,
    },
    .{
        .count = 1,
        .payload = &([_]u8{cellHeader(Cell.max_bytes + 1, 1, true)} ++ default_style ++ "abcdefghijklmnopq".*),
        .outcome = error.InvalidCell,
    },
    .{
        .count = 1,
        .payload = &([_]u8{cellHeader(1, max_width + 1, true)} ++ default_style ++ " ".*),
        .outcome = error.InvalidCell,
    },
    .{
        .count = 1,
        .payload = &([_]u8{cellHeader(1, 0, true)} ++ default_style ++ " ".*),
        .outcome = error.InvalidCell,
    },
    .{
        .count = 1,
        .payload = &([_]u8{cellHeader(0, 1, true)} ++ default_style),
        .outcome = error.InvalidCell,
    },
    .{
        .count = 1,
        .payload = &([_]u8{cellHeader(1, 1, true)} ++ reserved_flag ++ default_colors ++ " ".*),
        .outcome = error.InvalidStyle,
    },
    .{
        .count = 1,
        .payload = &([_]u8{cellHeader(1, 1, true)} ++ unknown_underline ++ default_colors ++ " ".*),
        .outcome = error.InvalidStyle,
    },
    .{
        .count = 1,
        .payload = &([_]u8{cellHeader(1, 1, true)} ++ flagBytes(0) ++ [_]u8{ @intFromEnum(Color.Kind.rgb) + 1, 0, 0, ' ' }),
        .outcome = error.InvalidColor,
    },
    .{
        .count = 1,
        .payload = &([_]u8{cellHeader(1, 1, true)} ++ flagBytes(0) ++ [_]u8{@intFromEnum(Color.Kind.default)}),
        .outcome = error.Truncated,
    },
    .{
        .count = 1,
        .payload = &([_]u8{cellHeader(2, 1, true)} ++ default_style ++ "a".*),
        .outcome = error.Truncated,
    },
    .{
        .count = 2,
        .payload = &default_cell,
        .outcome = error.Truncated,
    },
    .{
        .count = 1,
        .payload = &(default_cell ++ [_]u8{0}),
        .outcome = error.TrailingBytes,
    },
};

/// The seeds in `std.testing.Smith` input form: one little-endian u64 for
/// the promised count, then a slice as a little-endian u32 length and its
/// bytes. A crash the fuzzer saves has the same form, so it can join this
/// corpus as it is.
const cell_run_corpus = corpus: {
    var entries: [cell_run_seeds.len][]const u8 = undefined;
    for (cell_run_seeds, &entries) |seed, *entry| {
        entry.* = smithInput(seed.count, seed.payload);
    }

    break :corpus entries;
};

fn smithInput(comptime count: u64, comptime payload: []const u8) []const u8 {
    comptime {
        var count_bytes: [@sizeOf(u64)]u8 = undefined;
        std.mem.writeInt(u64, &count_bytes, count, .little);
        var length: [@sizeOf(u32)]u8 = undefined;
        std.mem.writeInt(u32, &length, payload.len, .little);
        const entry = count_bytes ++ length ++ payload[0..payload.len].*;
        return &entry;
    }
}

/// Reads every promised cell of `payload` and returns the first error.
fn runOutcome(payload: []const u8, count: u32) ?CellRunError {
    var reader = CellReader.init(payload, count);
    while (reader.next()) |cell| {
        if (cell == null) {
            return null;
        }
    } else |err| {
        return err;
    }
}

fn referenceOutcome(payload: []const u8, count: u32) ?CellRunError {
    var reader: ReferenceReader = .{
        .decoder = .init(payload),
        .remaining = count,
    };
    while (reader.next()) |cell| {
        if (cell == null) {
            return null;
        }
    } else |err| {
        return err;
    }
}

/// A broken property panics instead of returning its error: Zig 0.16.0's
/// fuzzer saves the failing input on an abort, but leaves it empty when the
/// test returns an error and the runner exits.
fn decodeFuzzedCellRun(_: void, smith: *Smith) anyerror!void {
    expectCellRunDecoding(smith) catch |err| std.debug.panic("cell run decoding property failed: {t}", .{err});
}

/// Reads a fuzzed payload for a fuzzed count. Every step must match the
/// reference reader: the same canonical cell, the same end or the same
/// error. A run read to its end must encode again to cells that read back
/// the same, and to exactly the payload when no header repeated a style.
fn expectCellRunDecoding(smith: *Smith) anyerror!void {
    const count = smith.valueRangeAtMost(u32, 0, max_fuzzed_cells);
    var buffer: [payload_capacity]u8 = undefined;
    const payload = buffer[0..smith.slice(&buffer)];

    var reader = CellReader.init(payload, count);
    var reference: ReferenceReader = .{
        .decoder = .init(payload),
        .remaining = count,
    };
    var cells: [max_fuzzed_cells]Cell = undefined;
    var cell_count: usize = 0;
    var canonical = true;
    while (true) {
        const expected = reference.next() catch |err| {
            return std.testing.expectError(err, reader.next());
        };

        const actual = try reader.next();
        const next = expected orelse {
            try std.testing.expectEqual(null, actual);
            break;
        };

        try std.testing.expectEqualDeep(next.cell, actual.?);
        cells[cell_count] = actual.?;
        cell_count += 1;
        canonical = canonical and !next.redundant_style;
    }

    if (count == 0) {
        return;
    }

    var encoded_buffer: [payload_capacity]u8 = undefined;
    var encoder = Encoder.init(&encoded_buffer);
    try cellcodec.encode(&encoder, cells[0..cell_count], unlimited);
    const encoded = encoder.finish();
    try std.testing.expectEqual(cellcodec.encodedCellsSize(cells[0..cell_count], null), encoded.len);
    if (canonical) {
        try std.testing.expectEqualSlices(u8, payload, encoded);
    } else {
        try std.testing.expect(encoded.len < payload.len);
    }

    var again = CellReader.init(encoded, count);
    for (cells[0..cell_count]) |cell| {
        try std.testing.expectEqualDeep(cell, (try again.next()).?);
    }

    try std.testing.expectEqual(null, try again.next());
}

/// One way a generated cell breaks `encode`'s rules, and none.
const CellFault = enum {
    none,
    text_too_long,
    width_too_large,
    text_without_width,
    width_without_text,
    reserved_flags,
};

const cell_fault_weights = [_]Smith.Weight{
    .value(CellFault, .none, 4),
    .rangeAtMost(CellFault, .text_too_long, .reserved_flags, 1),
};

fn generatedColor(smith: *Smith) Color {
    var color: Color = .{
        .kind = smith.value(Color.Kind),
    };
    smith.bytes(&color.value);
    return color;
}

fn generatedStyle(smith: *Smith) Style {
    const underline = smith.valueRangeAtMost(u16, @intFromEnum(Style.Underline.none), @intFromEnum(Style.Underline.dashed));
    const attributes = smith.value(u16) & attribute_bits;
    return .{
        .flags = @bitCast(attributes | underline << underline_shift),
        .fg = generatedColor(smith),
        .bg = generatedColor(smith),
        .underline_color = generatedColor(smith),
    };
}

/// A valid cell whose bytes past its text and unused color channels hold
/// whatever the fuzzer chose. It keeps `previous` most of the time, so runs
/// exercise inherited styles.
fn generatedCell(smith: *Smith, previous: ?Style) Cell {
    const width = smith.valueRangeAtMost(u8, 0, max_width);
    var cell: Cell = .{
        .len = if (width == 0) 0 else smith.valueRangeAtMost(u8, 1, Cell.max_bytes),
        .width = width,
    };
    smith.bytes(&cell.bytes);
    cell.style = if (previous != null and smith.boolWeighted(1, 3)) previous.? else generatedStyle(smith);
    return cell;
}

/// Breaks one rule in `cell` and returns the error `encode` owes it.
fn injectFault(smith: *Smith, cell: *Cell, fault: CellFault) CellRunError {
    switch (fault) {
        .none => unreachable,
        .text_too_long => {
            cell.len = smith.valueRangeAtMost(u8, Cell.max_bytes + 1, std.math.maxInt(u8));
            cell.width = 1;
            return error.InvalidCell;
        },
        .width_too_large => {
            cell.width = smith.valueRangeAtMost(u8, max_width + 1, std.math.maxInt(u8));
            return error.InvalidCell;
        },
        .text_without_width => {
            cell.len = smith.valueRangeAtMost(u8, 1, Cell.max_bytes);
            cell.width = 0;
            return error.InvalidCell;
        },
        .width_without_text => {
            cell.len = 0;
            cell.width = smith.valueRangeAtMost(u8, 1, max_width);
            return error.InvalidCell;
        },
        .reserved_flags => {
            const reserved = smith.valueRangeAtMost(u16, 1, reserved_flag_bits >> first_reserved_flag_bit);
            cell.style.flags = @bitCast(@as(u16, @bitCast(cell.style.flags)) | reserved << first_reserved_flag_bit);
            return error.InvalidStyle;
        },
    }
}

fn encodeFuzzedCells(_: void, smith: *Smith) anyerror!void {
    expectGeneratedCellRun(smith) catch |err| std.debug.panic("generated cell run property failed: {t}", .{err});
}

/// Generates a run, sometimes with one broken cell. A broken run must fail
/// with that cell's error on both of `encode`'s paths; a valid one goes
/// through `expectEncodedRun`.
fn expectGeneratedCellRun(smith: *Smith) anyerror!void {
    var cells: [max_fuzzed_cells]Cell = undefined;
    const count = smith.valueRangeAtMost(u32, 0, max_fuzzed_cells);
    for (cells[0..count], 0..) |*cell, index| {
        cell.* = generatedCell(smith, if (index == 0) null else cells[index - 1].style);
    }

    const run = cells[0..count];
    const fault = smith.valueWeighted(CellFault, &cell_fault_weights);
    if (fault == .none or count == 0) {
        return expectEncodedRun(smith, run);
    }

    const expected = injectFault(smith, &cells[smith.index(count)], fault);
    var buffer: [payload_capacity]u8 = undefined;
    var reserved = Encoder.init(&buffer);
    try std.testing.expectError(expected, cellcodec.encode(&reserved, run, unlimited));

    // One byte under the worst case forces the per-cell checks; the cells
    // before the broken one fit under it.
    var checked = Encoder.init(&buffer);
    try std.testing.expectError(expected, cellcodec.encode(&checked, run, count * cellcodec.max_cell_size - 1));
}

/// Encodes a valid run after a prefix with spare capacity, an exact-size
/// buffer and an exact limit. Every encoding must write the same bytes and
/// `referenceRunSize` of them. Exact-size cases take the checked path unless
/// the run fills its worst-case size.
/// One byte less of buffer or limit is an error, and every encoding reads
/// back as the cells' decoded form.
fn expectEncodedRun(smith: *Smith, run: []const Cell) anyerror!void {
    const size = cellcodec.encodedCellsSize(run, null);
    try std.testing.expectEqual(referenceRunSize(run, null), size);

    const previous = if (run.len != 0 and smith.boolWeighted(1, 1)) run[0].style else generatedStyle(smith);
    try std.testing.expectEqual(referenceRunSize(run, previous), cellcodec.encodedCellsSize(run, previous));

    const prefix = smith.valueRangeAtMost(u32, 0, max_prefix);
    var reserved_buffer: [max_prefix + payload_capacity]u8 = undefined;
    var reserved = Encoder.init(&reserved_buffer);
    reserved.index = prefix;
    try cellcodec.encode(&reserved, run, unlimited);
    try std.testing.expectEqual(prefix + size, reserved.index);
    const encoded = reserved_buffer[prefix..reserved.index];

    var exact_buffer: [max_prefix + payload_capacity]u8 = undefined;
    var exact = Encoder.init(exact_buffer[0 .. prefix + size]);
    exact.index = prefix;
    try cellcodec.encode(&exact, run, unlimited);
    try std.testing.expectEqualSlices(u8, encoded, exact_buffer[prefix..exact.index]);

    var limited = Encoder.init(&exact_buffer);
    limited.index = prefix;
    try cellcodec.encode(&limited, run, prefix + size);
    try std.testing.expectEqualSlices(u8, encoded, exact_buffer[prefix..limited.index]);

    if (size != 0) {
        var short = Encoder.init(exact_buffer[0 .. prefix + size - 1]);
        short.index = prefix;
        try std.testing.expectError(error.BufferTooSmall, cellcodec.encode(&short, run, unlimited));

        var over = Encoder.init(&exact_buffer);
        over.index = prefix;
        try std.testing.expectError(error.LimitExceeded, cellcodec.encode(&over, run, prefix + size - 1));
        try std.testing.expect(over.index <= prefix + size - 1);
    }

    var reader = CellReader.init(encoded, @intCast(run.len));
    var reference: ReferenceReader = .{
        .decoder = .init(encoded),
        .remaining = @intCast(run.len),
    };
    for (run) |cell| {
        const expected = decodedForm(cell);
        try std.testing.expectEqualDeep(expected, (try reader.next()).?);
        try std.testing.expectEqualDeep(expected, (try reference.next()).?.cell);
    }

    try std.testing.expectEqual(null, try reader.next());
}

test "every cell run fuzz seed reaches its decoder outcome" {
    for (cell_run_seeds, cell_run_corpus) |seed, entry| {
        try std.testing.expectEqual(seed.outcome, runOutcome(seed.payload, seed.count));
        try std.testing.expectEqual(seed.outcome, referenceOutcome(seed.payload, seed.count));

        var smith: Smith = .{ .in = entry };
        try std.testing.expectEqual(seed.count, smith.valueRangeAtMost(u32, 0, max_fuzzed_cells));
        var buffer: [payload_capacity]u8 = undefined;
        try std.testing.expectEqualSlices(u8, seed.payload, buffer[0..smith.slice(&buffer)]);
    }
}

test "fuzz cell run decoding" {
    try std.testing.fuzz({}, decodeFuzzedCellRun, .{
        .corpus = &cell_run_corpus,
    });
}

test "fuzz generated cell runs" {
    try std.testing.fuzz({}, encodeFuzzedCells, .{});
}
