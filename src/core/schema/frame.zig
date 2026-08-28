//! Pane screen snapshots and patches for Telar's current protocol.

const std = @import("std");
const ui = @import("../ui/root.zig");
const transport = @import("../transport/root.zig");
const wire = @import("wire.zig");
const id = @import("id.zig");

pub const max_span_count = 4096;
pub const cell_header_size = 1;
pub const max_style_size = 14;
pub const max_cell_size = cell_header_size + max_style_size + ui.Cell.max_bytes;
pub const body_header_size = 54;
pub const span_header_size = 12;
pub const max_body_size = transport.max_frame_size - 1;
pub const max_cell_count: u32 = @intCast(
    (max_body_size - body_header_size - span_header_size) / max_cell_size,
);

pub const Cursor = struct {
    visible: bool = false,
    x: u16 = 0,
    y: u16 = 0,
};

pub const MouseTracking = enum(u8) {
    none = 0,
    x10 = 1,
    normal = 2,
    button = 3,
    any = 4,
};

pub const Mouse = struct {
    tracking: MouseTracking = .none,
    sgr: bool = false,
    pixels: bool = false,
};

/// Child-controlled modes required to encode semantic keyboard and paste
/// input. The runtime derives these from its VT; the client never guesses.
pub const InputModes = struct {
    cursor_keys: bool = false,
    keypad_keys: bool = false,
    bracketed_paste: bool = false,
    focus_events: bool = false,
    alternate_scroll: bool = false,
    alternate_screen: bool = false,
    kitty_keyboard_flags: u5 = 0,
    modify_other_keys_2: bool = false,
};

/// Position of one client's viewport in the runtime-owned scrollback.
pub const Scroll = struct {
    total_rows: u32,
    offset: u32,

    pub fn maxOffset(scroll: Scroll, rows: u16) u32 {
        return scroll.total_rows -| rows;
    }

    pub fn atBottom(scroll: Scroll, rows: u16) bool {
        return scroll.offset == scroll.maxOffset(rows);
    }
};

pub const Span = struct {
    start: u32,
    cells: []const ui.Cell,
};

pub const Frame = struct {
    pane_id: id.PaneId,
    frame_id: u64,
    /// Zero denotes a full snapshot. A patch names the last acknowledged frame
    /// it was computed from.
    base_frame_id: u64,
    cols: u16,
    rows: u16,
    cursor: Cursor = .{},
    mouse: Mouse = .{},
    input_modes: InputModes = .{},
    scroll: Scroll,
    spans: []const Span,
};

pub const FrameView = struct {
    pane_id: id.PaneId,
    frame_id: u64,
    base_frame_id: u64,
    cols: u16,
    rows: u16,
    cursor: Cursor,
    mouse: Mouse,
    input_modes: InputModes,
    scroll: Scroll,
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

    pub fn next(iterator: *SpanIterator) error{Truncated}!?SpanView {
        if (iterator.remaining == 0) return null;
        iterator.remaining -= 1;

        const start = try iterator.decoder.readInt(u32);
        const count = try iterator.decoder.readInt(u32);
        const encoded_length = try iterator.decoder.readInt(u32);
        const encoded_cells = try iterator.decoder.readBytes(encoded_length);
        return .{
            .start = start,
            .cell_count = count,
            .encoded_cells = encoded_cells,
        };
    }
};

pub const CellIterator = struct {
    decoder: wire.Decoder,
    remaining: u32,
    style: ?ui.Style = null,

    pub fn next(iterator: *CellIterator) !?ui.Cell {
        if (iterator.remaining == 0) return null;
        iterator.remaining -= 1;
        const cell = try decodeCell(&iterator.decoder, &iterator.style);
        // The span header promised exactly `cell_count` cells; leftover bytes
        // after the last one are corruption, not padding.
        if (iterator.remaining == 0) try iterator.decoder.ensureEnd();
        return cell;
    }
};

pub fn encodeBody(encoder: *wire.Encoder, frame: Frame) !void {
    try validateFrameStructure(frame);
    const body_start = encoder.index;
    try encoder.writeInt(u64, id.raw(frame.pane_id));
    try encoder.writeInt(u64, frame.frame_id);
    try encoder.writeInt(u64, frame.base_frame_id);
    try encoder.writeInt(u16, frame.cols);
    try encoder.writeInt(u16, frame.rows);
    try encoder.writeByte(@intFromBool(frame.cursor.visible));
    try encoder.writeInt(u16, frame.cursor.x);
    try encoder.writeInt(u16, frame.cursor.y);
    try encoder.writeByte(@intFromEnum(frame.mouse.tracking));
    try encoder.writeByte(@intFromBool(frame.mouse.sgr));
    try encoder.writeByte(@intFromBool(frame.mouse.pixels));
    try encoder.writeByte(@intFromBool(frame.input_modes.cursor_keys));
    try encoder.writeByte(@intFromBool(frame.input_modes.keypad_keys));
    try encoder.writeByte(@intFromBool(frame.input_modes.bracketed_paste));
    try encoder.writeByte(@intFromBool(frame.input_modes.focus_events));
    try encoder.writeByte(@intFromBool(frame.input_modes.alternate_scroll));
    try encoder.writeByte(@intFromBool(frame.input_modes.alternate_screen));
    try encoder.writeByte(frame.input_modes.kitty_keyboard_flags);
    try encoder.writeByte(@intFromBool(frame.input_modes.modify_other_keys_2));
    try encoder.writeInt(u32, frame.scroll.total_rows);
    try encoder.writeInt(u32, frame.scroll.offset);
    try encoder.writeInt(u16, @intCast(frame.spans.len));

    for (frame.spans) |span| {
        try encoder.writeInt(u32, span.start);
        try encoder.writeInt(u32, @intCast(span.cells.len));
        const length_index = encoder.index;
        try encoder.writeInt(u32, 0);
        const cells_start = encoder.index;
        try encodeCells(encoder, span.cells, body_start);
        const encoded_length = encoder.index - cells_start;
        if (encoded_length > std.math.maxInt(u32)) return error.FrameTooLarge;
        std.mem.writeInt(
            u32,
            encoder.buffer[length_index..][0..@sizeOf(u32)],
            @intCast(encoded_length),
            .little,
        );
    }
}

pub fn decodeBody(decoder: *wire.Decoder) !FrameView {
    const body_start = decoder.index;
    const pane_id = try id.pane(try decoder.readInt(u64));
    const frame_id = try decoder.readInt(u64);
    const base_frame_id = try decoder.readInt(u64);
    const cols = try decoder.readInt(u16);
    const rows = try decoder.readInt(u16);
    const cursor_visible = try decoder.readBool();
    const cursor_x = try decoder.readInt(u16);
    const cursor_y = try decoder.readInt(u16);
    const mouse: Mouse = .{
        .tracking = switch (try decoder.readByte()) {
            0 => .none,
            1 => .x10,
            2 => .normal,
            3 => .button,
            4 => .any,
            else => return error.InvalidMouseTracking,
        },
        .sgr = try decoder.readBool(),
        .pixels = try decoder.readBool(),
    };
    const input_modes: InputModes = .{
        .cursor_keys = try decoder.readBool(),
        .keypad_keys = try decoder.readBool(),
        .bracketed_paste = try decoder.readBool(),
        .focus_events = try decoder.readBool(),
        .alternate_scroll = try decoder.readBool(),
        .alternate_screen = try decoder.readBool(),
        .kitty_keyboard_flags = std.math.cast(u5, try decoder.readByte()) orelse
            return error.InvalidKeyboardFlags,
        .modify_other_keys_2 = try decoder.readBool(),
    };
    const scroll: Scroll = .{
        .total_rows = try decoder.readInt(u32),
        .offset = try decoder.readInt(u32),
    };
    const span_count = try decoder.readInt(u16);

    try validateHeader(
        pane_id,
        frame_id,
        base_frame_id,
        cols,
        rows,
        .{ .visible = cursor_visible, .x = cursor_x, .y = cursor_y },
        scroll,
        span_count,
    );

    // Structural validation only: span ordering, grid coverage, and sizes.
    // Cell payloads are validated by `CellIterator` as the consumer decodes
    // them, so a frame's cells are only decoded once.
    const total_cells = try gridCellCount(cols, rows);
    const spans_start = decoder.index;
    var previous_end: u32 = 0;
    var first_start: u32 = 0;
    var first_count: u32 = 0;
    for (0..span_count) |span_index| {
        const start = try decoder.readInt(u32);
        const count = try decoder.readInt(u32);
        const encoded_length = try decoder.readInt(u32);
        const end = std.math.add(u32, start, count) catch return error.InvalidSpan;
        if (count == 0 or start < previous_end or end > total_cells)
            return error.InvalidSpan;
        if (span_index == 0) {
            first_start = start;
            first_count = count;
        }
        previous_end = end;
        // A cell is at least its header byte, so a length that cannot hold
        // `count` cells is structurally invalid.
        if (encoded_length < count) return error.InvalidSpan;
        _ = try decoder.readBytes(encoded_length);
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
        .mouse = mouse,
        .input_modes = input_modes,
        .scroll = scroll,
        .span_count = span_count,
        .encoded_spans = decoder.consumed(spans_start),
    };
}

/// Header and span-layout validation only, O(spans) without touching cells.
/// Cell payloads are validated by `encodeCells` as they are written, so a
/// frame's cells are only walked once on the encode side.
fn validateFrameStructure(frame: Frame) !void {
    try validateHeader(
        frame.pane_id,
        frame.frame_id,
        frame.base_frame_id,
        frame.cols,
        frame.rows,
        frame.cursor,
        frame.scroll,
        frame.spans.len,
    );
    const total_cells = try gridCellCount(frame.cols, frame.rows);
    var previous_end: u32 = 0;
    for (frame.spans) |span| {
        if (span.cells.len > std.math.maxInt(u32)) return error.InvalidSpan;
        const count: u32 = @intCast(span.cells.len);
        const end = std.math.add(u32, span.start, count) catch return error.InvalidSpan;
        if (count == 0 or span.start < previous_end or end > total_cells)
            return error.InvalidSpan;
        previous_end = end;
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
    pane_id: id.PaneId,
    frame_id: u64,
    base_frame_id: u64,
    cols: u16,
    rows: u16,
    cursor: Cursor,
    scroll: Scroll,
    span_count: usize,
) !void {
    if (pane_id == .invalid) return error.InvalidPaneId;
    if (frame_id == 0 or base_frame_id >= frame_id) return error.InvalidFrameId;
    _ = try gridCellCount(cols, rows);
    if (span_count > max_span_count) return error.TooManySpans;
    if (cursor.visible and (cursor.x >= cols or cursor.y >= rows)) return error.InvalidCursor;
    if (!cursor.visible and (cursor.x != 0 or cursor.y != 0)) return error.InvalidCursor;
    if (scroll.total_rows < rows or scroll.offset > scroll.maxOffset(rows))
        return error.InvalidScroll;
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

const length_mask: u8 = 0x1f;
const width_shift = 5;
const style_changed_bit: u8 = 0x80;

fn encodeCells(encoder: *wire.Encoder, cells: []const ui.Cell, body_start: usize) !void {
    var previous_style: ?ui.Style = null;
    for (cells) |cell| {
        try validateCell(cell);
        const style_changed = previous_style == null or
            !previous_style.?.eql(cell.style);
        // The budget check precedes the write so an oversized frame reports
        // FrameTooLarge, never the encoder's BufferTooSmall.
        const cell_size = cell_header_size + cell.len +
            if (style_changed) encodedStyleSize(cell.style) else 0;
        if (encoder.index - body_start + cell_size > max_body_size)
            return error.FrameTooLarge;
        const header = cell.len |
            (cell.width << width_shift) |
            if (style_changed) style_changed_bit else 0;
        try encoder.writeByte(header);
        if (style_changed) try encodeStyle(encoder, cell.style);
        try encoder.writeBytes(cell.bytes[0..cell.len]);
        previous_style = cell.style;
    }
}

/// Exact wire size of a cell run, excluding its span header.
/// `previous_style` models a run appended to an existing span.
pub fn encodedCellsSize(cells: []const ui.Cell, previous_style: ?ui.Style) usize {
    var size: usize = 0;
    var style = previous_style;
    for (cells) |cell| {
        size += encodedCellSize(cell, style);
        style = cell.style;
    }
    return size;
}

pub fn encodedCellSize(cell: ui.Cell, previous_style: ?ui.Style) usize {
    const style_changed = previous_style == null or !previous_style.?.eql(cell.style);
    return cell_header_size + cell.len +
        if (style_changed) encodedStyleSize(cell.style) else 0;
}

fn encodeStyle(encoder: *wire.Encoder, style: ui.Style) !void {
    try encoder.writeInt(u16, @bitCast(style.flags));
    try encodeColor(encoder, style.fg);
    try encodeColor(encoder, style.bg);
    try encodeColor(encoder, style.underline_color);
}

fn decodeCell(decoder: *wire.Decoder, previous_style: *?ui.Style) !ui.Cell {
    const header = try decoder.readByte();
    const length = header & length_mask;
    const width = (header >> width_shift) & 0x3;
    const style_changed = header & style_changed_bit != 0;
    if (!style_changed and previous_style.* == null) return error.InvalidCell;
    const style = if (style_changed)
        try decodeStyle(decoder)
    else
        previous_style.*.?;
    if (length > ui.Cell.max_bytes) return error.InvalidCell;
    const text = try decoder.readBytes(length);

    var cell: ui.Cell = .{
        .len = length,
        .width = width,
        .style = style,
    };
    std.mem.copyForwards(u8, cell.bytes[0..length], text);
    try validateCell(cell);
    previous_style.* = style;
    return cell;
}

fn decodeStyle(decoder: *wire.Decoder) !ui.Style {
    const flags_bits = try decoder.readInt(u16);
    try validateFlags(flags_bits);
    return .{
        .flags = @bitCast(flags_bits),
        .fg = try decodeColor(decoder),
        .bg = try decodeColor(decoder),
        .underline_color = try decodeColor(decoder),
    };
}

fn encodedStyleSize(style: ui.Style) usize {
    return @sizeOf(u16) + encodedColorSize(style.fg) +
        encodedColorSize(style.bg) + encodedColorSize(style.underline_color);
}

fn encodedColorSize(color: ui.Color) usize {
    return switch (color) {
        .default => 1,
        .indexed => 2,
        .rgb => 4,
    };
}

fn validateFlags(bits: u16) !void {
    if (bits & 0xf800 != 0) return error.InvalidStyle;
    if ((bits >> 8) & 0x7 > @intFromEnum(ui.Style.Underline.dashed))
        return error.InvalidStyle;
}

fn encodeColor(encoder: *wire.Encoder, color: ui.Color) !void {
    switch (color) {
        .default => try encoder.writeByte(0),
        .indexed => |index| {
            try encoder.writeByte(1);
            try encoder.writeByte(index);
        },
        .rgb => |rgb| {
            try encoder.writeByte(2);
            try encoder.writeBytes(&rgb);
        },
    }
}

fn decodeColor(decoder: *wire.Decoder) !ui.Color {
    const tag = try decoder.readByte();
    return switch (tag) {
        0 => .default,
        1 => .{ .indexed = try decoder.readByte() },
        2 => .{ .rgb = (try decoder.readBytes(3))[0..3].* },
        else => error.InvalidColor,
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
        .pane_id = @enumFromInt(7),
        .frame_id = 1,
        .base_frame_id = 0,
        .cols = 2,
        .rows = 1,
        .cursor = .{ .visible = true, .x = 1, .y = 0 },
        .scroll = .{ .total_rows = 1, .offset = 0 },
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
    const span = (try span_iterator.next()).?;
    try std.testing.expectEqual(@as(u32, 2), span.cell_count);
    var cell_iterator = span.cells();
    try std.testing.expectEqualDeep(cells[0], (try cell_iterator.next()).?);
    try std.testing.expectEqualDeep(cells[1], (try cell_iterator.next()).?);
    try std.testing.expect((try cell_iterator.next()) == null);
}

test "a style run pays two bytes per ordinary cell" {
    const cells = [_]ui.Cell{ .{}, .{}, .{} };
    const spans = [_]Span{.{ .start = 0, .cells = &cells }};
    var buffer: [128]u8 = undefined;
    var encoder = wire.Encoder.init(&buffer);
    try encodeBody(&encoder, .{
        .pane_id = @enumFromInt(1),
        .frame_id = 1,
        .base_frame_id = 0,
        .cols = 3,
        .rows = 1,
        .scroll = .{ .total_rows = 1, .offset = 0 },
        .spans = &spans,
    });

    // The first cell carries the five-byte default style and costs seven
    // bytes. Each following space costs only its packed header and text byte.
    const cells_start = body_header_size + span_header_size;
    try std.testing.expectEqual(@as(usize, cells_start + 11), encoder.finish().len);
    try std.testing.expectEqual(@as(u8, 0xa1), encoder.finish()[cells_start]);
    try std.testing.expectEqual(@as(u8, 0x21), encoder.finish()[cells_start + 7]);
    try std.testing.expectEqual(@as(u8, 0x21), encoder.finish()[cells_start + 9]);
}

test "cell run size accounts for inherited style" {
    const cells = [_]ui.Cell{ .{}, .{}, .{} };
    try std.testing.expectEqual(@as(usize, 11), encodedCellsSize(&cells, null));
    try std.testing.expectEqual(@as(usize, 6), encodedCellsSize(&cells, .{}));
}

test "the first cell of every span must define its style" {
    const cells = [_]ui.Cell{.{}};
    const spans = [_]Span{.{ .start = 0, .cells = &cells }};
    var buffer: [128]u8 = undefined;
    var encoder = wire.Encoder.init(&buffer);
    try encodeBody(&encoder, .{
        .pane_id = @enumFromInt(1),
        .frame_id = 1,
        .base_frame_id = 0,
        .cols = 1,
        .rows = 1,
        .scroll = .{ .total_rows = 1, .offset = 0 },
        .spans = &spans,
    });

    buffer[body_header_size + span_header_size] &= ~style_changed_bit;
    var decoder = wire.Decoder.init(encoder.finish());
    // Cell content is validated when the consumer iterates, not at decode.
    const decoded = try decodeBody(&decoder);
    var span_iterator = decoded.spans();
    var cell_iterator = ((try span_iterator.next()).?).cells();
    try std.testing.expectError(error.InvalidCell, cell_iterator.next());
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
        .pane_id = @enumFromInt(1),
        .frame_id = 2,
        .base_frame_id = 1,
        .cols = 2,
        .rows = 1,
        .scroll = .{ .total_rows = 1, .offset = 0 },
        .spans = &overlapping,
    }));
}

test "a snapshot must contain the complete grid" {
    const cell = [_]ui.Cell{.{}};
    const spans = [_]Span{.{ .start = 0, .cells = &cell }};
    var buffer: [256]u8 = undefined;
    var encoder = wire.Encoder.init(&buffer);
    try std.testing.expectError(error.InvalidSnapshot, encodeBody(&encoder, .{
        .pane_id = @enumFromInt(1),
        .frame_id = 1,
        .base_frame_id = 0,
        .cols = 2,
        .rows = 1,
        .scroll = .{ .total_rows = 1, .offset = 0 },
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

test "scroll metadata cannot point beyond retained history" {
    const cells = [_]ui.Cell{.{}} ** 2;
    const spans = [_]Span{.{ .start = 0, .cells = &cells }};
    var buffer: [256]u8 = undefined;
    var encoder = wire.Encoder.init(&buffer);
    try std.testing.expectError(error.InvalidScroll, encodeBody(&encoder, .{
        .pane_id = @enumFromInt(1),
        .frame_id = 1,
        .base_frame_id = 0,
        .cols = 1,
        .rows = 2,
        .scroll = .{ .total_rows = 10, .offset = 9 },
        .spans = &spans,
    }));
}
