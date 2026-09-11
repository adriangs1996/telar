//! Pane screen snapshots and patches for Telar's current protocol.

const CellType = @import("../ui/Cell.zig");
const transport = @import("../transport/transport.zig");
const EncoderType = @import("Encoder.zig");
const Frame = @import("Frame.zig");
const id = @import("id.zig");
const std = @import("std");
const DecoderType = @import("Decoder.zig");
const FrameView = @import("FrameView.zig");
const Mouse = @import("Mouse.zig");
const InputModes = @import("InputModes.zig");
const Scroll = @import("Scroll.zig");
const Header = @import("Header.zig");
const StyleType = @import("../ui/Style.zig");
const cell_support = @import("../ui/cell_support.zig");
const Span = @import("Span.zig");

pub const max_span_count = 4096;
pub const cell_header_size = 1;
pub const max_style_size = 14;
pub const max_cell_size = cell_header_size + max_style_size + CellType.max_bytes;
pub const body_header_size = 55;
pub const span_header_size = 12;
pub const max_body_size = transport.max_frame_size - 1;
pub const max_cell_count: u32 = @intCast(
    (max_body_size - body_header_size - span_header_size) / max_cell_size,
);

/// Canonical OSC 22 shapes. Wire values are independent of the VT's enum ABI.
pub const PointerShape = enum(u8) {
    default = 0,
    context_menu = 1,
    help = 2,
    pointer = 3,
    progress = 4,
    wait = 5,
    cell = 6,
    crosshair = 7,
    text = 8,
    vertical_text = 9,
    alias = 10,
    copy = 11,
    move = 12,
    no_drop = 13,
    not_allowed = 14,
    grab = 15,
    grabbing = 16,
    all_scroll = 17,
    col_resize = 18,
    row_resize = 19,
    n_resize = 20,
    e_resize = 21,
    s_resize = 22,
    w_resize = 23,
    ne_resize = 24,
    nw_resize = 25,
    se_resize = 26,
    sw_resize = 27,
    ew_resize = 28,
    ns_resize = 29,
    nesw_resize = 30,
    nwse_resize = 31,
    zoom_in = 32,
    zoom_out = 33,
};

pub const MouseTracking = enum(u8) {
    none = 0,
    x10 = 1,
    normal = 2,
    button = 3,
    any = 4,
};

pub fn encodeBody(encoder: *EncoderType, frame: Frame) !void {
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
    try encoder.writeByte(@intFromEnum(frame.pointer_shape));
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
        if (encoded_length > std.math.maxInt(u32)) {
            return error.FrameTooLarge;
        }
        std.mem.writeInt(
            u32,
            encoder.buffer[length_index..][0..@sizeOf(u32)],
            @intCast(encoded_length),
            .little,
        );
    }
}

pub fn decodeBody(decoder: *DecoderType) !FrameView {
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
    const pointer_shape = std.enums.fromInt(PointerShape, try decoder.readByte()) orelse
        return error.InvalidPointerShape;
    const scroll: Scroll = .{
        .total_rows = try decoder.readInt(u32),
        .offset = try decoder.readInt(u32),
    };
    const span_count = try decoder.readInt(u16);

    try validateHeader(.{
        .pane_id = pane_id,
        .frame_id = frame_id,
        .base_frame_id = base_frame_id,
        .cols = cols,
        .rows = rows,
        .cursor = .{ .visible = cursor_visible, .x = cursor_x, .y = cursor_y },
        .scroll = scroll,
        .span_count = span_count,
    });

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
        if (count == 0 or start < previous_end or end > total_cells) {
            return error.InvalidSpan;
        }
        if (span_index == 0) {
            first_start = start;
            first_count = count;
        }
        previous_end = end;
        // A cell is at least its header byte, so a length that cannot hold
        // `count` cells is structurally invalid.
        if (encoded_length < count) {
            return error.InvalidSpan;
        }
        _ = try decoder.readBytes(encoded_length);
    }
    if (base_frame_id == 0 and
        (span_count != 1 or first_start != 0 or first_count != total_cells))
    {
        return error.InvalidSnapshot;
    }
    if (decoder.index - body_start > max_body_size) {
        return error.FrameTooLarge;
    }

    return .{
        .pane_id = pane_id,
        .frame_id = frame_id,
        .base_frame_id = base_frame_id,
        .cols = cols,
        .rows = rows,
        .cursor = .{ .visible = cursor_visible, .x = cursor_x, .y = cursor_y },
        .mouse = mouse,
        .input_modes = input_modes,
        .pointer_shape = pointer_shape,
        .scroll = scroll,
        .span_count = span_count,
        .encoded_spans = decoder.consumed(spans_start),
    };
}

/// Header and span-layout validation only, O(spans) without touching cells.
/// Cell payloads are validated by `encodeCells` as they are written, so a
/// frame's cells are only walked once on the encode side.
fn validateFrameStructure(frame: Frame) !void {
    try validateHeader(.{
        .pane_id = frame.pane_id,
        .frame_id = frame.frame_id,
        .base_frame_id = frame.base_frame_id,
        .cols = frame.cols,
        .rows = frame.rows,
        .cursor = frame.cursor,
        .scroll = frame.scroll,
        .span_count = frame.spans.len,
    });
    const total_cells = try gridCellCount(frame.cols, frame.rows);
    var previous_end: u32 = 0;
    for (frame.spans) |span| {
        if (span.cells.len > std.math.maxInt(u32)) {
            return error.InvalidSpan;
        }
        const count: u32 = @intCast(span.cells.len);
        const end = std.math.add(u32, span.start, count) catch return error.InvalidSpan;
        if (count == 0 or span.start < previous_end or end > total_cells) {
            return error.InvalidSpan;
        }
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

fn validateHeader(header: Header) !void {
    if (header.pane_id == .invalid) {
        return error.InvalidPaneId;
    }
    if (header.frame_id == 0 or header.base_frame_id >= header.frame_id) {
        return error.InvalidFrameId;
    }
    _ = try gridCellCount(header.cols, header.rows);
    if (header.span_count > max_span_count) {
        return error.TooManySpans;
    }
    if (header.cursor.visible and (header.cursor.x >= header.cols or header.cursor.y >= header.rows)) {
        return error.InvalidCursor;
    }
    if (!header.cursor.visible and (header.cursor.x != 0 or header.cursor.y != 0)) {
        return error.InvalidCursor;
    }
    if (header.scroll.total_rows < header.rows or header.scroll.offset > header.scroll.maxOffset(header.rows)) {
        return error.InvalidScroll;
    }
}

fn gridCellCount(cols: u16, rows: u16) !u32 {
    if (cols == 0 or rows == 0) {
        return error.InvalidTerminalSize;
    }
    const count = @as(u32, cols) * @as(u32, rows);
    if (count > max_cell_count) {
        return error.ScreenTooLarge;
    }
    return count;
}

fn validateCell(cell: CellType) !void {
    if (cell.len > CellType.max_bytes) {
        return error.InvalidCell;
    }
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

fn encodeCells(encoder: *EncoderType, cells: []const CellType, body_start: usize) !void {
    var previous_style: ?StyleType = null;
    for (cells) |cell| {
        try validateCell(cell);
        const style_changed = previous_style == null or
            !previous_style.?.eql(cell.style);
        // The budget check precedes the write so an oversized frame reports
        // FrameTooLarge, never the encoder's BufferTooSmall.
        const cell_size = cell_header_size + cell.len +
            if (style_changed) encodedStyleSize(cell.style) else 0;
        if (encoder.index - body_start + cell_size > max_body_size) {
            return error.FrameTooLarge;
        }
        const header = cell.len |
            (cell.width << width_shift) |
            if (style_changed) style_changed_bit else 0;
        try encoder.writeByte(header);
        if (style_changed) {
            try encodeStyle(encoder, cell.style);
        }
        try encoder.writeBytes(cell.bytes[0..cell.len]);
        previous_style = cell.style;
    }
}

/// Exact wire size of a cell run, excluding its span header.
/// `previous_style` models a run appended to an existing span.
pub fn encodedCellsSize(cells: []const CellType, previous_style: ?StyleType) usize {
    var size: usize = 0;
    var style = previous_style;
    for (cells) |cell| {
        size += encodedCellSize(cell, style);
        style = cell.style;
    }
    return size;
}

pub fn encodedCellSize(cell: CellType, previous_style: ?StyleType) usize {
    const style_changed = previous_style == null or !previous_style.?.eql(cell.style);
    return cell_header_size + cell.len +
        if (style_changed) encodedStyleSize(cell.style) else 0;
}

fn encodeStyle(encoder: *EncoderType, style: StyleType) !void {
    try encoder.writeInt(u16, @bitCast(style.flags));
    try encodeColor(encoder, style.fg);
    try encodeColor(encoder, style.bg);
    try encodeColor(encoder, style.underline_color);
}

pub fn decodeCell(decoder: *DecoderType, previous_style: *?StyleType) !CellType {
    const header = try decoder.readByte();
    const length = header & length_mask;
    const width = (header >> width_shift) & 0x3;
    const style_changed = header & style_changed_bit != 0;
    if (!style_changed and previous_style.* == null) {
        return error.InvalidCell;
    }
    const style = if (style_changed)
        try decodeStyle(decoder)
    else
        previous_style.*.?;
    if (length > CellType.max_bytes) {
        return error.InvalidCell;
    }
    const text = try decoder.readBytes(length);

    var cell: CellType = .{
        .len = length,
        .width = width,
        .style = style,
    };
    std.mem.copyForwards(u8, cell.bytes[0..length], text);
    try validateCell(cell);
    previous_style.* = style;
    return cell;
}

fn decodeStyle(decoder: *DecoderType) !StyleType {
    const flags_bits = try decoder.readInt(u16);
    try validateFlags(flags_bits);
    return .{
        .flags = @bitCast(flags_bits),
        .fg = try decodeColor(decoder),
        .bg = try decodeColor(decoder),
        .underline_color = try decodeColor(decoder),
    };
}

fn encodedStyleSize(style: StyleType) usize {
    return @sizeOf(u16) + encodedColorSize(style.fg) +
        encodedColorSize(style.bg) + encodedColorSize(style.underline_color);
}

fn encodedColorSize(color: cell_support.Color) usize {
    return switch (color) {
        .default => 1,
        .indexed => 2,
        .rgb => 4,
    };
}

fn validateFlags(bits: u16) !void {
    if (bits & 0xf800 != 0) {
        return error.InvalidStyle;
    }
    if ((bits >> 8) & 0x7 > @intFromEnum(StyleType.Underline.dashed)) {
        return error.InvalidStyle;
    }
}

fn encodeColor(encoder: *EncoderType, color: cell_support.Color) !void {
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

fn decodeColor(decoder: *DecoderType) !cell_support.Color {
    const tag = try decoder.readByte();
    return switch (tag) {
        0 => .default,
        1 => .{ .indexed = try decoder.readByte() },
        2 => .{ .rgb = (try decoder.readBytes(3))[0..3].* },
        else => error.InvalidColor,
    };
}

test "full snapshots preserve cells, styles and cursor" {
    const cells = [_]CellType{
        .{},
        .{
            .bytes = [_]u8{'x'} ++ [_]u8{0} ** (CellType.max_bytes - 1),
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
    var encoder = EncoderType.init(&buffer);
    try encodeBody(&encoder, frame);
    var decoder = DecoderType.init(encoder.finish());
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
    const cells = [_]CellType{ .{}, .{}, .{} };
    const spans = [_]Span{.{ .start = 0, .cells = &cells }};
    var buffer: [128]u8 = undefined;
    var encoder = EncoderType.init(&buffer);
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
    const cells = [_]CellType{ .{}, .{}, .{} };
    try std.testing.expectEqual(@as(usize, 11), encodedCellsSize(&cells, null));
    try std.testing.expectEqual(@as(usize, 6), encodedCellsSize(&cells, .{}));
}

test "the first cell of every span must define its style" {
    const cells = [_]CellType{.{}};
    const spans = [_]Span{.{ .start = 0, .cells = &cells }};
    var buffer: [128]u8 = undefined;
    var encoder = EncoderType.init(&buffer);
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
    var decoder = DecoderType.init(encoder.finish());
    // Cell content is validated when the consumer iterates, not at decode.
    const decoded = try decodeBody(&decoder);
    var span_iterator = decoded.spans();
    var cell_iterator = ((try span_iterator.next()).?).cells();
    try std.testing.expectError(error.InvalidCell, cell_iterator.next());
}

test "patch spans must be ordered and inside the screen" {
    const cell = [_]CellType{.{}};
    const overlapping = [_]Span{
        .{ .start = 1, .cells = &cell },
        .{ .start = 1, .cells = &cell },
    };
    var buffer: [256]u8 = undefined;
    var encoder = EncoderType.init(&buffer);
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
    const cell = [_]CellType{.{}};
    const spans = [_]Span{.{ .start = 0, .cells = &cell }};
    var buffer: [256]u8 = undefined;
    var encoder = EncoderType.init(&buffer);
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
    const cells = [_]CellType{.{}} ** 2;
    const spans = [_]Span{.{ .start = 0, .cells = &cells }};
    var buffer: [256]u8 = undefined;
    var encoder = EncoderType.init(&buffer);
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
