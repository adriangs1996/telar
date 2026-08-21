//! Pane screen snapshots and patches for protocol version 1.

const std = @import("std");
const ui = @import("../../ui.zig");
const transport = @import("../../transport.zig");
const wire = @import("wire.zig");

pub const max_span_count = 4096;
pub const cell_fixed_size = 16;
pub const max_cell_size = cell_fixed_size + ui.Cell.max_bytes;
pub const body_header_size = 35;
pub const span_header_size = 8;
pub const max_body_size = transport.max_frame_size - 1;
pub const max_cell_count: u32 = @intCast(
    (max_body_size - body_header_size - span_header_size) / max_cell_size,
);

pub const Cursor = struct {
    visible: bool = false,
    x: u16 = 0,
    y: u16 = 0,
};

pub const Span = struct {
    start: u32,
    cells: []const ui.Cell,
};

pub const Frame = struct {
    pane_id: u64,
    frame_id: u64,
    /// Zero denotes a full snapshot. A patch names the last acknowledged frame
    /// it was computed from.
    base_frame_id: u64,
    cols: u16,
    rows: u16,
    cursor: Cursor = .{},
    spans: []const Span,
};

pub const FrameView = struct {
    pane_id: u64,
    frame_id: u64,
    base_frame_id: u64,
    cols: u16,
    rows: u16,
    cursor: Cursor,
    span_count: u16,
    encoded_spans: []const u8,

    pub fn isSnapshot(frame: FrameView) bool {
        return frame.base_frame_id == 0;
    }

    pub fn spans(frame: FrameView) SpanIterator {
        return .{
            .decoder = .init(frame.encoded_spans),
            .remaining = frame.span_count,
        };
    }
};

pub const SpanView = struct {
    start: u32,
    cell_count: u32,
    encoded_cells: []const u8,

    pub fn cells(span: SpanView) CellIterator {
        return .{
            .decoder = .init(span.encoded_cells),
            .remaining = span.cell_count,
        };
    }
};

pub const SpanIterator = struct {
    decoder: wire.Decoder,
    remaining: u16,

    pub fn next(iterator: *SpanIterator) ?SpanView {
        if (iterator.remaining == 0) return null;
        iterator.remaining -= 1;

        const start = iterator.decoder.readInt(u32) catch unreachable;
        const count = iterator.decoder.readInt(u32) catch unreachable;
        const cells_start = iterator.decoder.index;
        for (0..count) |_| _ = decodeCell(&iterator.decoder) catch unreachable;
        return .{
            .start = start,
            .cell_count = count,
            .encoded_cells = iterator.decoder.consumed(cells_start),
        };
    }
};

pub const CellIterator = struct {
    decoder: wire.Decoder,
    remaining: u32,

    pub fn next(iterator: *CellIterator) ?ui.Cell {
        if (iterator.remaining == 0) return null;
        iterator.remaining -= 1;
        return decodeCell(&iterator.decoder) catch unreachable;
    }
};

pub fn encodeBody(encoder: *wire.Encoder, frame: Frame) !void {
    try validateFrame(frame);
    try encoder.writeInt(u64, frame.pane_id);
    try encoder.writeInt(u64, frame.frame_id);
    try encoder.writeInt(u64, frame.base_frame_id);
    try encoder.writeInt(u16, frame.cols);
    try encoder.writeInt(u16, frame.rows);
    try encoder.writeByte(@intFromBool(frame.cursor.visible));
    try encoder.writeInt(u16, frame.cursor.x);
    try encoder.writeInt(u16, frame.cursor.y);
    try encoder.writeInt(u16, @intCast(frame.spans.len));

    for (frame.spans) |span| {
        try encoder.writeInt(u32, span.start);
        try encoder.writeInt(u32, @intCast(span.cells.len));
        for (span.cells) |cell| try encodeCell(encoder, cell);
    }
}

pub fn decodeBody(decoder: *wire.Decoder) !FrameView {
    const body_start = decoder.index;
    const pane_id = try decoder.readInt(u64);
    const frame_id = try decoder.readInt(u64);
    const base_frame_id = try decoder.readInt(u64);
    const cols = try decoder.readInt(u16);
    const rows = try decoder.readInt(u16);
    const cursor_visible = try decodeBool(try decoder.readByte());
    const cursor_x = try decoder.readInt(u16);
    const cursor_y = try decoder.readInt(u16);
    const span_count = try decoder.readInt(u16);

    try validateHeader(
        pane_id,
        frame_id,
        base_frame_id,
        cols,
        rows,
        .{ .visible = cursor_visible, .x = cursor_x, .y = cursor_y },
        span_count,
    );

    const total_cells = try gridCellCount(cols, rows);
    const spans_start = decoder.index;
    var previous_end: u32 = 0;
    var first_start: u32 = 0;
    var first_count: u32 = 0;
    for (0..span_count) |span_index| {
        const start = try decoder.readInt(u32);
        const count = try decoder.readInt(u32);
        const end = std.math.add(u32, start, count) catch return error.InvalidSpan;
        if (start < previous_end or end > total_cells) return error.InvalidSpan;
        if (span_index == 0) {
            first_start = start;
            first_count = count;
        }
        previous_end = end;
        for (0..count) |_| _ = try decodeCell(decoder);
    }
    if (base_frame_id == 0 and
        (span_count != 1 or first_start != 0 or first_count != total_cells))
    {
        return error.InvalidSnapshot;
    }
    if (decoder.index - body_start > max_body_size) return error.FrameTooLarge;

    return .{
        .pane_id = pane_id,
        .frame_id = frame_id,
        .base_frame_id = base_frame_id,
        .cols = cols,
        .rows = rows,
        .cursor = .{ .visible = cursor_visible, .x = cursor_x, .y = cursor_y },
        .span_count = span_count,
        .encoded_spans = decoder.consumed(spans_start),
    };
}

fn validateFrame(frame: Frame) !void {
    try validateHeader(
        frame.pane_id,
        frame.frame_id,
        frame.base_frame_id,
        frame.cols,
        frame.rows,
        frame.cursor,
        frame.spans.len,
    );
    const total_cells = try gridCellCount(frame.cols, frame.rows);
    var encoded_size: usize = body_header_size;
    var previous_end: u32 = 0;
    for (frame.spans) |span| {
        if (span.cells.len > std.math.maxInt(u32)) return error.InvalidSpan;
        const count: u32 = @intCast(span.cells.len);
        const end = std.math.add(u32, span.start, count) catch return error.InvalidSpan;
        if (span.start < previous_end or end > total_cells) return error.InvalidSpan;
        previous_end = end;
        encoded_size = std.math.add(usize, encoded_size, span_header_size) catch
            return error.FrameTooLarge;
        for (span.cells) |cell| {
            try validateCell(cell);
            encoded_size = std.math.add(
                usize,
                encoded_size,
                cell_fixed_size + cell.len,
            ) catch return error.FrameTooLarge;
            if (encoded_size > max_body_size) return error.FrameTooLarge;
        }
    }
    if (frame.base_frame_id == 0 and
        (frame.spans.len != 1 or
            frame.spans[0].start != 0 or
            frame.spans[0].cells.len != total_cells))
    {
        return error.InvalidSnapshot;
    }
}

fn validateHeader(
    pane_id: u64,
    frame_id: u64,
    base_frame_id: u64,
    cols: u16,
    rows: u16,
    cursor: Cursor,
    span_count: usize,
) !void {
    if (pane_id == 0) return error.InvalidPaneId;
    if (frame_id == 0 or base_frame_id >= frame_id) return error.InvalidFrameId;
    _ = try gridCellCount(cols, rows);
    if (span_count > max_span_count) return error.TooManySpans;
    if (cursor.visible and (cursor.x >= cols or cursor.y >= rows)) return error.InvalidCursor;
    if (!cursor.visible and (cursor.x != 0 or cursor.y != 0)) return error.InvalidCursor;
}

fn gridCellCount(cols: u16, rows: u16) !u32 {
    if (cols == 0 or rows == 0) return error.InvalidTerminalSize;
    const count = @as(u32, cols) * @as(u32, rows);
    if (count > max_cell_count) return error.ScreenTooLarge;
    return count;
}

fn validateCell(cell: ui.Cell) !void {
    if (cell.len > ui.Cell.max_bytes) return error.InvalidCell;
    switch (cell.width) {
        0 => if (cell.len != 0) return error.InvalidCell,
        1, 2 => if (cell.len == 0) return error.InvalidCell,
        else => return error.InvalidCell,
    }
    try validateFlags(@bitCast(cell.style.flags));
}

fn encodeCell(encoder: *wire.Encoder, cell: ui.Cell) !void {
    try encoder.writeByte(cell.len);
    try encoder.writeByte(cell.width);
    try encoder.writeInt(u16, @bitCast(cell.style.flags));
    try encodeColor(encoder, cell.style.fg);
    try encodeColor(encoder, cell.style.bg);
    try encodeColor(encoder, cell.style.underline_color);
    try encoder.writeBytes(cell.bytes[0..cell.len]);
}

fn decodeCell(decoder: *wire.Decoder) !ui.Cell {
    const length = try decoder.readByte();
    const width = try decoder.readByte();
    const flags_bits = try decoder.readInt(u16);
    try validateFlags(flags_bits);
    const foreground = try decodeColor(decoder);
    const background = try decodeColor(decoder);
    const underline_color = try decodeColor(decoder);
    if (length > ui.Cell.max_bytes) return error.InvalidCell;
    const text = try decoder.readBytes(length);

    var cell: ui.Cell = .{
        .len = length,
        .width = width,
        .style = .{
            .fg = foreground,
            .bg = background,
            .underline_color = underline_color,
            .flags = @bitCast(flags_bits),
        },
    };
    std.mem.copyForwards(u8, cell.bytes[0..length], text);
    try validateCell(cell);
    return cell;
}

fn validateFlags(bits: u16) !void {
    if (bits & 0xf800 != 0) return error.InvalidStyle;
    if ((bits >> 8) & 0x7 > @intFromEnum(ui.Style.Underline.dashed))
        return error.InvalidStyle;
}

fn encodeColor(encoder: *wire.Encoder, color: ui.Color) !void {
    switch (color) {
        .default => {
            try encoder.writeByte(0);
            try encoder.writeBytes(&.{ 0, 0, 0 });
        },
        .indexed => |index| {
            try encoder.writeByte(1);
            try encoder.writeBytes(&.{ index, 0, 0 });
        },
        .rgb => |rgb| {
            try encoder.writeByte(2);
            try encoder.writeBytes(&rgb);
        },
    }
}

fn decodeColor(decoder: *wire.Decoder) !ui.Color {
    const tag = try decoder.readByte();
    const payload = try decoder.readBytes(3);
    return switch (tag) {
        0 => if (std.mem.eql(u8, payload, &.{ 0, 0, 0 })) .default else error.InvalidColor,
        1 => if (payload[1] == 0 and payload[2] == 0)
            .{ .indexed = payload[0] }
        else
            error.InvalidColor,
        2 => .{ .rgb = payload[0..3].* },
        else => error.InvalidColor,
    };
}

fn decodeBool(value: u8) !bool {
    return switch (value) {
        0 => false,
        1 => true,
        else => error.InvalidBoolean,
    };
}

test "full snapshots preserve cells, styles and cursor" {
    const cells = [_]ui.Cell{
        .{},
        .{
            .bytes = [_]u8{'x'} ++ [_]u8{0} ** (ui.Cell.max_bytes - 1),
            .len = 1,
            .width = 1,
            .style = .{
                .fg = .{ .rgb = .{ 1, 2, 3 } },
                .bg = .{ .indexed = 4 },
                .flags = .{ .bold = true, .underline = .curly },
            },
        },
    };
    const spans = [_]Span{.{ .start = 0, .cells = &cells }};
    const frame = Frame{
        .pane_id = 7,
        .frame_id = 1,
        .base_frame_id = 0,
        .cols = 2,
        .rows = 1,
        .cursor = .{ .visible = true, .x = 1, .y = 0 },
        .spans = &spans,
    };

    var buffer: [256]u8 = undefined;
    var encoder = wire.Encoder.init(&buffer);
    try encodeBody(&encoder, frame);
    var decoder = wire.Decoder.init(encoder.finish());
    const decoded = try decodeBody(&decoder);
    try decoder.ensureEnd();

    try std.testing.expect(decoded.isSnapshot());
    try std.testing.expectEqual(frame.pane_id, decoded.pane_id);
    try std.testing.expectEqual(frame.cursor, decoded.cursor);
    var span_iterator = decoded.spans();
    const span = span_iterator.next().?;
    try std.testing.expectEqual(@as(u32, 2), span.cell_count);
    var cell_iterator = span.cells();
    try std.testing.expectEqualDeep(cells[0], cell_iterator.next().?);
    try std.testing.expectEqualDeep(cells[1], cell_iterator.next().?);
    try std.testing.expect(cell_iterator.next() == null);
}

test "patch spans must be ordered and inside the screen" {
    const cell = [_]ui.Cell{.{}};
    const overlapping = [_]Span{
        .{ .start = 1, .cells = &cell },
        .{ .start = 1, .cells = &cell },
    };
    var buffer: [256]u8 = undefined;
    var encoder = wire.Encoder.init(&buffer);
    try std.testing.expectError(error.InvalidSpan, encodeBody(&encoder, .{
        .pane_id = 1,
        .frame_id = 2,
        .base_frame_id = 1,
        .cols = 2,
        .rows = 1,
        .spans = &overlapping,
    }));
}

test "a snapshot must contain the complete grid" {
    const cell = [_]ui.Cell{.{}};
    const spans = [_]Span{.{ .start = 0, .cells = &cell }};
    var buffer: [256]u8 = undefined;
    var encoder = wire.Encoder.init(&buffer);
    try std.testing.expectError(error.InvalidSnapshot, encodeBody(&encoder, .{
        .pane_id = 1,
        .frame_id = 1,
        .base_frame_id = 0,
        .cols = 2,
        .rows = 1,
        .spans = &spans,
    }));
}

test "the maximum screen is bounded by one transport frame" {
    const maximum_snapshot_size = 1 + body_header_size + span_header_size +
        @as(usize, max_cell_count) * max_cell_size;
    const next_snapshot_size = maximum_snapshot_size + max_cell_size;

    try std.testing.expect(maximum_snapshot_size <= transport.max_frame_size);
    try std.testing.expect(next_snapshot_size > transport.max_frame_size);
}
