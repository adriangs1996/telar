//! Runs of `cellgrid` cells in a compact format: one header byte per cell
//! packs its text length, its width and whether its style differs from the
//! previous cell's; only a changed style is written, and each color takes
//! just the channels its kind needs.

const bytecodec = @import("bytecodec");
const cellgrid = @import("cellgrid");
const std = @import("std");
const Encoder = bytecodec.Encoder;
const Decoder = bytecodec.Decoder;
const Cell = cellgrid.Cell;
const Style = cellgrid.Style;
const Color = cellgrid.cell_support.Color;

pub const cell_header_size = 1;
/// Flags plus three colors with every channel present.
pub const max_style_size = 14;
pub const max_cell_size = cell_header_size + max_style_size + Cell.max_bytes;
/// Header bit set on a cell that carries its own style.
pub const style_changed_bit: u8 = 0x80;

const length_mask: u8 = 0x1f;
const width_shift = 5;
const width_mask: u8 = 0x3;
const reserved_flag_bits: u16 = 0xf800;
const underline_shift = 8;
const underline_mask: u16 = 0x7;
const rgb_channels = 3;

/// Writes `cells` as one run starting with a full style. The run fails with
/// `error.LimitExceeded` before the encoder index would pass `limit`, so a
/// caller bounding a larger message reports its own size error.
///
/// ```zig
/// try cell_run.encode(&encoder, span.cells, body_start + max_body_size);
/// ```
pub fn encode(encoder: *Encoder, cells: []const Cell, limit: usize) !void {
    // When the worst case of the whole run fits both the limit and the
    // buffer, neither check can fail per cell, so the run is written without
    // them. The output bytes are identical either way.
    const worst = std.math.mul(usize, cells.len, max_cell_size) catch std.math.maxInt(usize);
    if (encoder.index +| worst <= limit and encoder.buffer.len - encoder.index >= worst) {
        return encodeWithin(encoder, cells);
    }

    var previous_style: ?Style = null;
    for (cells) |cell| {
        try validateCell(cell);

        const style_changed = previous_style == null or !previous_style.?.eql(cell.style);

        // The limit check precedes the write so an oversized run reports
        // LimitExceeded, never the encoder's BufferTooSmall.
        const cell_size = cell_header_size + cell.len + if (style_changed) encodedStyleSize(cell.style) else 0;
        if (encoder.index +| cell_size > limit) {
            return error.LimitExceeded;
        }

        try encoder.writeByte(header(cell, style_changed));
        if (style_changed) {
            try encodeStyle(encoder, cell.style);
        }

        try encoder.writeBytes(cell.bytes[0..cell.len]);
        previous_style = cell.style;
    }
}

/// Reads one cell. `previous_style` carries the style between the cells of
/// one run and must start null; a first cell without its own style fails.
///
/// ```zig
/// var style: ?Style = null;
/// const cell = try cell_run.decodeCell(&decoder, &style);
/// ```
pub fn decodeCell(decoder: *Decoder, previous_style: *?Style) !Cell {
    const cell_header = try decoder.readByte();
    const length = cell_header & length_mask;
    const width = (cell_header >> width_shift) & width_mask;
    const style_changed = cell_header & style_changed_bit != 0;
    if (!style_changed and previous_style.* == null) {
        return error.InvalidCell;
    }

    const style = if (style_changed)
        try decodeStyle(decoder)
    else
        previous_style.*.?;
    if (length > Cell.max_bytes) {
        return error.InvalidCell;
    }

    const text = try decoder.readBytes(length);
    var cell: Cell = .{
        .len = length,
        .width = width,
        .style = style,
    };

    std.mem.copyForwards(u8, cell.bytes[0..length], text);
    try validateCell(cell);
    previous_style.* = style;
    return cell;
}

/// Exact encoded size of a cell run. `previous_style` models a run appended
/// to an existing one.
///
/// ```zig
/// const size = cell_run.encodedCellsSize(cells, null);
/// ```
pub fn encodedCellsSize(cells: []const Cell, previous_style: ?Style) usize {
    var size: usize = 0;
    var style = previous_style;
    for (cells) |cell| {
        size += encodedCellSize(cell, style);
        style = cell.style;
    }

    return size;
}

/// Exact encoded size of one cell after a cell styled `previous_style`.
///
/// ```zig
/// const size = cell_run.encodedCellSize(cell, previous.style);
/// ```
pub fn encodedCellSize(cell: Cell, previous_style: ?Style) usize {
    const style_changed = previous_style == null or !previous_style.?.eql(cell.style);
    return cell_header_size + cell.len + if (style_changed) encodedStyleSize(cell.style) else 0;
}

/// Writes a run whose worst-case size is already reserved. Each cell stores
/// its complete inline text and advances by `len`; the extra bytes stay
/// past the encoder index and inside the reservation, and the next cell or
/// `finish` never exposes them.
fn encodeWithin(encoder: *Encoder, cells: []const Cell) !void {
    const out = encoder.buffer;
    var index = encoder.index;
    defer encoder.index = index;

    var previous_style: ?Style = null;
    for (cells) |cell| {
        try validateCell(cell);

        const style_changed = previous_style == null or !previous_style.?.eql(cell.style);
        out[index] = header(cell, style_changed);
        index += cell_header_size;
        if (style_changed) {
            index += writeStyleWithin(out[index..], cell.style);
        }

        out[index..][0..Cell.max_bytes].* = cell.bytes;
        index += cell.len;
        previous_style = cell.style;
    }
}

fn header(cell: Cell, style_changed: bool) u8 {
    return cell.len | (cell.width << width_shift) | if (style_changed) style_changed_bit else 0;
}

fn writeStyleWithin(out: []u8, style: Style) usize {
    std.mem.writeInt(u16, out[0..2], @bitCast(style.flags), .little);

    var len: usize = @sizeOf(u16);
    inline for (.{ style.fg, style.bg, style.underline_color }) |color| {
        out[len..][0..4].* = @bitCast(color);
        len += encodedColorSize(color);
    }

    return len;
}

fn validateCell(cell: Cell) !void {
    if (cell.len > Cell.max_bytes) {
        return error.InvalidCell;
    }

    switch (cell.width) {
        0 => if (cell.len != 0) return error.InvalidCell,
        1, 2 => if (cell.len == 0) return error.InvalidCell,
        else => return error.InvalidCell,
    }

    try validateFlags(@bitCast(cell.style.flags));
}

fn encodeStyle(encoder: *Encoder, style: Style) !void {
    try encoder.writeInt(u16, @bitCast(style.flags));
    try encodeColor(encoder, style.fg);
    try encodeColor(encoder, style.bg);
    try encodeColor(encoder, style.underline_color);
}

fn decodeStyle(decoder: *Decoder) !Style {
    const flags_bits = try decoder.readInt(u16);
    try validateFlags(flags_bits);

    return .{
        .flags = @bitCast(flags_bits),
        .fg = try decodeColor(decoder),
        .bg = try decodeColor(decoder),
        .underline_color = try decodeColor(decoder),
    };
}

fn encodedStyleSize(style: Style) usize {
    return @sizeOf(u16) + encodedColorSize(style.fg) + encodedColorSize(style.bg) + encodedColorSize(style.underline_color);
}

fn encodedColorSize(color: Color) usize {
    return 1 + colorChannels(color);
}

/// Channels after the kind byte: none, the palette index, or RGB.
fn colorChannels(color: Color) usize {
    return switch (color.kind) {
        .default => 0,
        .indexed => 1,
        .rgb => rgb_channels,
    };
}

fn validateFlags(bits: u16) !void {
    if (bits & reserved_flag_bits != 0) {
        return error.InvalidStyle;
    }

    if ((bits >> underline_shift) & underline_mask > @intFromEnum(Style.Underline.dashed)) {
        return error.InvalidStyle;
    }
}

fn encodeColor(encoder: *Encoder, color: Color) !void {
    try encoder.writeByte(@intFromEnum(color.kind));
    try encoder.writeBytes(color.value[0..colorChannels(color)]);
}

fn decodeColor(decoder: *Decoder) !Color {
    const kind = std.enums.fromInt(Color.Kind, try decoder.readByte()) orelse return error.InvalidColor;

    return switch (kind) {
        .default => .default,
        .indexed => .indexed(try decoder.readByte()),
        .rgb => .rgb((try decoder.readBytes(rgb_channels))[0..rgb_channels].*),
    };
}
