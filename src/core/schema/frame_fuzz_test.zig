//! Native fuzzing of the pane frame body: `frame_support.decodeBody`, the
//! spans a `FrameView` walks and the cells a consumer reads from them, and
//! `encodeBody` for the frames it is given.
//!
//! `src/core/frame_fuzz_root.zig` is this file's test root, because
//! `frame_support.zig` imports `../text_metadata`; it runs only through
//! `zig build test-fuzz-frames-body`. `decodeBody` validates the header, the
//! metadata and the span layout, and leaves each span's cells to
//! `cellcodec.CellReader`: a structurally accepted frame may still hold cells
//! a consumer rejects, and every target here allows that.

const std = @import("std");
const bytecodec = @import("bytecodec");
const cellcodec = @import("cellcodec");
const cellgrid = @import("cellgrid");
const keyinput = @import("keyinput");
const Builder = @import("../text_metadata/Builder.zig");
const Cursor = @import("Cursor.zig");
const Frame = @import("Frame.zig");
const frame_support = @import("frame_support.zig");
const FrameView = @import("FrameView.zig");
const Mouse = @import("Mouse.zig");
const RowFlags = @import("../text_metadata/RowFlags.zig").RowFlags;
const Span = @import("Span.zig");
const text_metadata_limits = @import("../text_metadata/limits.zig");
const TextMetadataView = @import("../text_metadata/View.zig");
const Cell = cellgrid.Cell;
const Color = cellgrid.cell_support.Color;
const Decoder = bytecodec.Decoder;
const Encoder = bytecodec.Encoder;
const Smith = std.testing.Smith;
const Style = cellgrid.Style;

/// The largest body the decoding target reads. A cell is at least one byte
/// and a span at least its header and one cell, which bounds what one body
/// can hold.
const payload_capacity = 4096;
const max_payload_cells = payload_capacity;
const max_payload_spans = payload_capacity / (frame_support.span_header_size + cellcodec.cell_header_size);

const max_generated_cols = 16;
const max_generated_rows = 8;
const max_generated_spans = 8;
const max_generated_span_cells = 16;
const max_generated_cells = max_generated_spans * max_generated_span_cells;
const max_generated_links = 3;
const max_generated_uri_bytes = 16;
const max_generated_runs = 8;
const generated_body_capacity = 2 * payload_capacity;
const metadata_scratch_capacity = text_metadata_limits.capacity(max_generated_rows);
/// A wide glyph and the padding it displaces.
const wide_glyph_columns = 2;
const max_cell_width = 2;
const attribute_bits: u16 = 0x00ff;
const underline_shift = 8;

/// Where each header field starts in a body, as `encodeBody` writes it.
const HeaderField = enum(usize) {
    pane_id = 0,
    frame_id = 8,
    base_frame_id = 16,
    cols = 24,
    rows = 26,
    cursor_visible = 28,
    cursor_x = 29,
    cursor_y = 31,
    mouse_tracking = 33,
    mouse_sgr = 34,
    keyboard_flags = 42,
    modify_other_keys = 43,
    pointer_shape = 44,
    scroll_total_rows = 45,
    scroll_offset = 49,
    span_count = 53,
    cursor_shape = 55,
    cursor_blink = 56,
    metadata_length = 57,
};

/// Where each field starts in a span header.
const SpanField = enum(usize) {
    start = 0,
    count = 4,
    encoded_length = 8,
};

comptime {
    std.debug.assert(@intFromEnum(HeaderField.metadata_length) + @sizeOf(u32) == frame_support.body_header_size);
    std.debug.assert(@intFromEnum(SpanField.encoded_length) + @sizeOf(u32) == frame_support.span_header_size);
}

fn writeHeader(body: []u8, field: HeaderField, comptime T: type, value: T) void {
    std.mem.writeInt(T, body[@intFromEnum(field)..][0..@sizeOf(T)], value, .little);
}

/// Writes `cursor`'s visibility and position into `body` and `frame`.
fn moveCursor(body: []u8, frame: *Frame, cursor: Cursor) void {
    writeHeader(body, .cursor_visible, u8, @intFromBool(cursor.visible));
    writeHeader(body, .cursor_x, u16, cursor.x);
    writeHeader(body, .cursor_y, u16, cursor.y);
    frame.cursor = cursor;
}

fn readHeader(body: []const u8, field: HeaderField, comptime T: type) T {
    return std.mem.readInt(T, body[@intFromEnum(field)..][0..@sizeOf(T)], .little);
}

/// Where span `index` of a well-formed body starts.
fn spanOffset(body: []const u8, index: usize) usize {
    var offset: usize = frame_support.body_header_size + readHeader(body, .metadata_length, u32);
    for (0..index) |_| {
        offset += frame_support.span_header_size + std.mem.readInt(u32, body[offset + @intFromEnum(SpanField.encoded_length) ..][0..@sizeOf(u32)], .little);
    }

    return offset;
}

fn writeSpan(body: []u8, index: usize, field: SpanField, value: u32) void {
    std.mem.writeInt(u32, body[spanOffset(body, index) + @intFromEnum(field) ..][0..@sizeOf(u32)], value, .little);
}

fn readSpan(body: []const u8, index: usize, field: SpanField) u32 {
    return std.mem.readInt(u32, body[spanOffset(body, index) + @intFromEnum(field) ..][0..@sizeOf(u32)], .little);
}

fn isInside(inner: []const u8, outer: []const u8) bool {
    const start = @intFromPtr(inner.ptr);
    return start >= @intFromPtr(outer.ptr) and start + inner.len <= @intFromPtr(outer.ptr) + outer.len;
}

/// Whether a decoded cell keeps the cell rules `encode` enforces.
fn isValidCell(cell: Cell) bool {
    return cell.len <= Cell.max_bytes and cell.width <= max_cell_width and (cell.width == 0) == (cell.len == 0);
}

/// Every field a frame decodes to, spans aside, equals the frame's.
fn expectSameHeader(expected: Frame, actual: FrameView) !void {
    try std.testing.expectEqual(expected.pane_id, actual.pane_id);
    try std.testing.expectEqual(expected.frame_id, actual.frame_id);
    try std.testing.expectEqual(expected.base_frame_id, actual.base_frame_id);
    try std.testing.expectEqual(expected.cols, actual.cols);
    try std.testing.expectEqual(expected.rows, actual.rows);
    try std.testing.expectEqual(expected.cursor, actual.cursor);
    try std.testing.expectEqual(expected.mouse, actual.mouse);
    try std.testing.expectEqual(expected.input_modes, actual.input_modes);
    try std.testing.expectEqual(expected.pointer_shape, actual.pointer_shape);
    try std.testing.expectEqual(expected.scroll, actual.scroll);
    try std.testing.expectEqual(expected.spans.len, actual.span_count);
}

/// What a structurally accepted body promises its consumer: a valid header,
/// metadata that fits the screen, exactly `span_count` ordered, non-empty
/// spans inside the grid whose bytes tile `encoded_spans`, and a snapshot
/// that covers the grid with one span. Returns whether every span's cells
/// read too, which the structure does not promise.
fn expectAcceptedStructure(view: FrameView, body: []const u8, cells: *[max_payload_cells]Cell, spans: *[max_payload_spans]Span) !bool {
    try std.testing.expect(body.len <= frame_support.max_body_size);
    try std.testing.expect(view.pane_id != .invalid);
    try std.testing.expect(view.base_frame_id < view.frame_id);
    try std.testing.expect(view.cols != 0 and view.rows != 0);
    const grid = @as(u32, view.cols) * view.rows;
    try std.testing.expect(grid <= frame_support.max_cell_count);
    try std.testing.expect(view.span_count <= frame_support.max_span_count);
    if (view.cursor.visible) {
        try std.testing.expect(view.cursor.x < view.cols and view.cursor.y < view.rows);
    } else {
        try std.testing.expect(view.cursor.x == 0 and view.cursor.y == 0);
    }

    try std.testing.expect(view.scroll.total_rows >= view.rows);
    try std.testing.expect(view.scroll.offset <= view.scroll.total_rows - view.rows);
    try std.testing.expect(isInside(view.encoded_spans, body));

    if (view.isSnapshot()) {
        try std.testing.expect(view.text_metadata != null);
    }

    if (view.text_metadata) |metadata| {
        try expectMetadataFits(metadata, view.cols, view.rows, body);
    }

    var iterator = view.spans();
    var previous_end: u32 = 0;
    var span_bytes: usize = 0;
    var cell_count: usize = 0;
    var cells_read = true;
    for (0..view.span_count) |index| {
        const span = (try iterator.next()).?;
        try std.testing.expect(span.cell_count != 0);
        try std.testing.expect(span.start >= previous_end);
        try std.testing.expect(span.start <= grid and span.cell_count <= grid - span.start);
        try std.testing.expect(span.encoded_cells.len >= span.cell_count);
        try std.testing.expect(isInside(span.encoded_cells, view.encoded_spans));
        previous_end = span.start + span.cell_count;
        span_bytes += frame_support.span_header_size + span.encoded_cells.len;

        const span_cells = cells[cell_count..][0..span.cell_count];
        cells_read = try readSpanCells(span.cells(), span_cells, span.encoded_cells.len) and cells_read;
        spans[index] = .{
            .start = span.start,
            .cells = span_cells,
        };
        cell_count += span.cell_count;
    }

    try std.testing.expectEqual(null, try iterator.next());
    try std.testing.expectEqual(view.encoded_spans.len, span_bytes);
    if (view.isSnapshot()) {
        try std.testing.expectEqual(@as(u16, 1), view.span_count);
        try std.testing.expectEqual(@as(u32, 0), spans[0].start);
        try std.testing.expectEqual(@as(usize, grid), spans[0].cells.len);
    }

    return cells_read;
}

/// Reads one span's cells into `cells`. A rejection is the consumer's
/// normal answer to cells the structure never checked; an accepted run
/// holds valid cells and measures at most its encoded length.
fn readSpanCells(reader: cellcodec.CellReader, cells: []Cell, encoded_length: usize) !bool {
    var cells_reader = reader;
    for (cells) |*cell| {
        const next = cells_reader.next() catch return false;
        cell.* = next.?;
        try std.testing.expect(isValidCell(cell.*));
    }

    try std.testing.expectEqual(null, cells_reader.next() catch return false);
    try std.testing.expect(cellcodec.encodedCellsSize(cells, null) <= encoded_length);
    return true;
}

/// Metadata a frame accepted is borrowed from its body, has one flag per
/// row, and answers every link and run lookup inside its own bytes.
fn expectMetadataFits(metadata: TextMetadataView, cols: u16, rows: u16, body: []const u8) !void {
    try std.testing.expect(isInside(metadata.encoded, body));
    try std.testing.expectEqual(@as(usize, rows), metadata.rows.len);
    try std.testing.expectEqual(null, metadata.link(metadata.link_count));
    for (0..metadata.link_count) |index| {
        try std.testing.expect(isInside(metadata.link(@intCast(index)).?, metadata.uri_bytes));
    }

    const grid = @as(u32, cols) * rows;
    var runs = metadata.runs();
    var run_count: usize = 0;
    while (runs.next()) |run| : (run_count += 1) {
        try std.testing.expect(run.len != 0 and run.start < grid and run.len <= grid - run.start);
        try std.testing.expectEqual(run.start / cols, (run.start + run.len - 1) / cols);
        try std.testing.expect(metadata.link(run.link_index) != null);
        try std.testing.expectEqual(run, metadata.at(run.start).?);
        try std.testing.expectEqual(run, metadata.at(run.start + run.len - 1).?);
    }

    try std.testing.expectEqual(@as(usize, metadata.run_count), run_count);
}

/// Encodes an accepted body's decoded values again. The body must come
/// back byte for byte when its cells were written the way `encode` writes
/// them; otherwise the new body must decode to the same values.
fn expectReencodes(view: FrameView, body: []const u8, spans: []const Span) !void {
    const frame: Frame = .{
        .pane_id = view.pane_id,
        .frame_id = view.frame_id,
        .base_frame_id = view.base_frame_id,
        .cols = view.cols,
        .rows = view.rows,
        .cursor = view.cursor,
        .mouse = view.mouse,
        .input_modes = view.input_modes,
        .pointer_shape = view.pointer_shape,
        .text_metadata = view.text_metadata,
        .scroll = view.scroll,
        .spans = spans,
    };
    var buffer: [payload_capacity]u8 = undefined;
    var encoder = Encoder.init(&buffer);
    try frame_support.encodeBody(&encoder, frame);
    const encoded = encoder.finish();

    var canonical_length = frame_support.body_header_size + (if (view.text_metadata) |metadata| metadata.encoded.len else 0);
    for (spans) |span| {
        canonical_length += frame_support.span_header_size + cellcodec.encodedCellsSize(span.cells, null);
    }

    try std.testing.expectEqual(canonical_length, encoded.len);
    if (canonical_length == body.len) {
        return std.testing.expectEqualSlices(u8, body, encoded);
    }

    try std.testing.expect(encoded.len < body.len);
    try expectDecodesTo(frame, encoded);
}

/// `body` decodes, consuming all of it, to `frame`'s header, metadata,
/// spans and cells.
fn expectDecodesTo(frame: Frame, body: []const u8) !void {
    var decoder = Decoder.init(body);
    const view = try frame_support.decodeBody(&decoder);
    try std.testing.expectEqual(body.len, decoder.index);
    try expectSameHeader(frame, view);
    if (frame.text_metadata) |metadata| {
        try std.testing.expectEqualSlices(u8, metadata.encoded, view.text_metadata.?.encoded);
    } else if (frame.base_frame_id == 0) {
        const metadata = view.text_metadata.?;
        try std.testing.expectEqual(text_metadata_limits.Status.complete, metadata.status);
        try std.testing.expectEqual(@as(u16, 0), metadata.link_count);
        try std.testing.expectEqual(@as(u16, 0), metadata.run_count);
        for (metadata.rows) |flags| {
            try std.testing.expectEqual(RowFlags{}, flags);
        }
    } else {
        try std.testing.expectEqual(null, view.text_metadata);
    }

    var spans = view.spans();
    for (frame.spans) |expected| {
        const span = (try spans.next()).?;
        try std.testing.expectEqual(expected.start, span.start);
        try std.testing.expectEqual(expected.cells.len, span.cell_count);
        var cells = span.cells();
        for (expected.cells) |cell| {
            try std.testing.expectEqualDeep(cell, (try cells.next()).?);
        }

        try std.testing.expectEqual(null, try cells.next());
    }

    try std.testing.expectEqual(null, try spans.next());
}

/// A broken property panics instead of returning its error: Zig 0.16.0's
/// fuzzer saves the failing input on an abort, but leaves it empty when the
/// test returns an error and the runner exits.
fn decodeFuzzedBody(_: void, smith: *Smith) anyerror!void {
    expectBodyDecoding(smith) catch |err| std.debug.panic("frame body decoding property failed: {t}", .{err});
}

/// Decodes a fuzzed body. A rejection is a normal answer; an accepted body
/// must keep the structure's promises, and when its cells read too it must
/// encode back as `expectReencodes` says. `decodeBody` reads only the body,
/// so bytes after it are not its concern.
fn expectBodyDecoding(smith: *Smith) anyerror!void {
    var buffer: [payload_capacity]u8 = undefined;
    const payload = buffer[0..smith.slice(&buffer)];

    var decoder = Decoder.init(payload);
    const view = frame_support.decodeBody(&decoder) catch return;
    const body = payload[0..decoder.index];

    var cells: [max_payload_cells]Cell = undefined;
    var spans: [max_payload_spans]Span = undefined;
    if (try expectAcceptedStructure(view, body, &cells, &spans)) {
        try expectReencodes(view, body, spans[0..view.span_count]);
    }
}

/// Storage one generated frame borrows: its spans, their cells and its
/// metadata. The frame points into it, so it stays where it was generated.
const GeneratedFrame = struct {
    frame: Frame,
    spans: [max_generated_spans]Span,
    cells: [max_generated_cells]Cell,
    metadata: [metadata_scratch_capacity]u8,
};

fn generatedColor(smith: *Smith) Color {
    return switch (smith.value(Color.Kind)) {
        .default => .default,
        .indexed => .indexed(smith.value(u8)),
        .rgb => .rgb(smith.value([3]u8)),
    };
}

fn generatedStyle(smith: *Smith) Style {
    const underline = smith.valueRangeAtMost(u16, @intFromEnum(Style.Underline.none), @intFromEnum(Style.Underline.dashed));
    return .{
        .flags = @bitCast((smith.value(u16) & attribute_bits) | underline << underline_shift),
        .fg = generatedColor(smith),
        .bg = generatedColor(smith),
        .underline_color = generatedColor(smith),
    };
}

/// Valid cells in the form the decoder returns them, keeping the previous
/// style most of the time.
fn generateCells(smith: *Smith, cells: []Cell) []const Cell {
    for (cells, 0..) |*cell, index| {
        const width = smith.valueRangeAtMost(u8, 0, max_cell_width);
        cell.* = .{
            .len = if (width == 0) 0 else smith.valueRangeAtMost(u8, 1, Cell.max_bytes),
            .width = width,
            .style = if (index != 0 and smith.boolWeighted(1, 3)) cells[index - 1].style else generatedStyle(smith),
        };
        smith.bytes(cell.bytes[0..cell.len]);
    }

    return cells;
}

/// Ordered, non-empty spans inside a `cols`-wide grid of `grid` cells.
fn generatePatchSpans(smith: *Smith, generated: *GeneratedFrame, cols: u16, grid: u32) usize {
    var position: u32 = 0;
    var used: usize = 0;
    var span_count: usize = 0;
    const wanted = smith.valueRangeAtMost(u8, 0, max_generated_spans);
    while (span_count < wanted) : (span_count += 1) {
        const start = position + smith.valueRangeAtMost(u32, 0, cols);
        if (start >= grid) {
            break;
        }

        const count = smith.valueRangeAtMost(u32, 1, @min(grid - start, max_generated_span_cells));
        generated.spans[span_count] = .{
            .start = start,
            .cells = generateCells(smith, generated.cells[used..][0..count]),
        };
        used += count;
        position = start + count;
    }

    return span_count;
}

/// Legal metadata for the screen: row flags, a few links and sorted
/// row-local runs naming them.
fn generateMetadata(smith: *Smith, scratch: []u8, cols: u16, rows: u16) !TextMetadataView {
    var builder = Builder.init(scratch, rows);
    for (0..rows) |y| {
        const wrap = smith.value(bool);
        builder.setRow(@intCast(y), .{
            .wrap = wrap,
            .continuation = smith.value(bool),
            .wide_padding = wrap and cols >= wide_glyph_columns and smith.value(bool),
            .hyperlinks = smith.value(bool),
        });
    }

    var uri: [max_generated_uri_bytes]u8 = undefined;
    const link_count = smith.valueRangeAtMost(u16, 0, max_generated_links);
    for (0..link_count) |_| {
        const length = smith.valueRangeAtMost(u16, 1, max_generated_uri_bytes);
        smith.bytes(uri[0..length]);
        _ = try builder.addLink(uri[0..length]);
    }

    const grid = @as(u32, cols) * rows;
    var position: u32 = 0;
    const run_count = if (link_count == 0) 0 else smith.valueRangeAtMost(u8, 0, max_generated_runs);
    for (0..run_count) |_| {
        const start = position + smith.valueRangeAtMost(u32, 0, cols);
        if (start >= grid) {
            break;
        }

        const row_end = (start / cols + 1) * cols;
        const len = smith.valueRangeAtMost(u32, 1, row_end - start);
        try builder.addRun(.{
            .start = start,
            .len = len,
            .link_index = @intCast(smith.index(link_count)),
        });
        position = start + len;
    }

    return builder.finish(if (smith.boolWeighted(3, 1)) .complete else .omitted);
}

fn generatedCursor(smith: *Smith, cols: u16, rows: u16) Cursor {
    const visible = smith.value(bool);
    return .{
        .visible = visible,
        .x = if (visible) smith.valueRangeLessThan(u16, 0, cols) else 0,
        .y = if (visible) smith.valueRangeLessThan(u16, 0, rows) else 0,
        .appearance = .{
            .shape = smith.value(Cursor.Shape),
            .blink = smith.value(bool),
        },
    };
}

/// A valid snapshot or patch over a small screen, every header field drawn
/// from its whole valid range.
fn generateFrame(smith: *Smith, generated: *GeneratedFrame) !void {
    const cols = smith.valueRangeAtMost(u16, 1, max_generated_cols);
    const rows = smith.valueRangeAtMost(u16, 1, max_generated_rows);
    const grid = @as(u32, cols) * rows;
    const snapshot = smith.value(bool);
    const base_frame_id: u64 = if (snapshot) 0 else smith.valueRangeAtMost(u64, 1, std.math.maxInt(u64) - 1);
    const span_count = if (snapshot) 1 else generatePatchSpans(smith, generated, cols, grid);
    if (snapshot) {
        generated.spans[0] = .{
            .start = 0,
            .cells = generateCells(smith, generated.cells[0..grid]),
        };
    }

    const total_rows = smith.valueRangeAtMost(u32, rows, std.math.maxInt(u32));
    generated.frame = .{
        .pane_id = @enumFromInt(smith.valueRangeAtMost(u64, 1, std.math.maxInt(u64))),
        .frame_id = smith.valueRangeAtMost(u64, base_frame_id + 1, std.math.maxInt(u64)),
        .base_frame_id = base_frame_id,
        .cols = cols,
        .rows = rows,
        .cursor = generatedCursor(smith, cols, rows),
        .mouse = smith.value(Mouse),
        .input_modes = smith.value(keyinput.InputModes),
        .pointer_shape = smith.value(frame_support.PointerShape),
        .text_metadata = if (smith.boolWeighted(1, 2)) try generateMetadata(smith, &generated.metadata, cols, rows) else null,
        .scroll = .{
            .total_rows = total_rows,
            .offset = smith.valueRangeAtMost(u32, 0, total_rows - rows),
        },
        .spans = generated.spans[0..span_count],
    };
}

/// One rule a generated body breaks, and none. Faults a `Frame` can carry
/// break the value too, so `encodeBody` is held to the same rule.
const FrameFault = enum {
    none,
    truncated,
    zero_pane_id,
    zero_frame_id,
    stale_base,
    hidden_cursor_moved,
    cursor_outside,
    unknown_mouse_tracking,
    keyboard_flags_overflow,
    unknown_pointer_shape,
    unknown_cursor_shape,
    non_boolean,
    short_history,
    scroll_past_history,
    too_many_spans,
    oversized_metadata,
    snapshot_without_metadata,
    empty_span,
    overlapping_span,
    span_past_screen,
    partial_snapshot,
    short_cells,
};

const frame_fault_weights = [_]Smith.Weight{
    .value(FrameFault, .none, 8),
    .rangeAtMost(FrameFault, .truncated, .short_cells, 1),
};

/// The error a faulted body owes, the one `encodeBody` owes the faulted
/// value when a `Frame` can carry the fault, and the body's length.
const FaultExpectation = struct {
    decode: anyerror,
    encode: ?anyerror,
    body_len: usize,
};

const boolean_fields = [_]HeaderField{ .cursor_visible, .mouse_sgr, .modify_other_keys, .cursor_blink };

/// Breaks one rule in `body` and, when it can, in `frame` and `spans`,
/// which start as copies of the generated ones. Null when the fault does
/// not apply to this frame.
fn injectFault(smith: *Smith, fault: FrameFault, body: []u8, frame: *Frame, spans: []Span) ?FaultExpectation {
    const grid = @as(u32, frame.cols) * frame.rows;
    const snapshot = frame.base_frame_id == 0;
    const last_span = spans.len -% 1;
    switch (fault) {
        .none => return null,
        .truncated => return .{
            .decode = error.Truncated,
            .encode = null,
            .body_len = smith.index(body.len),
        },
        .zero_pane_id => {
            writeHeader(body, .pane_id, u64, 0);
            frame.pane_id = .invalid;
            return expectBoth(error.InvalidPaneId, body.len);
        },
        .zero_frame_id => {
            writeHeader(body, .frame_id, u64, 0);
            frame.frame_id = 0;
            return expectBoth(error.InvalidFrameId, body.len);
        },
        .stale_base => {
            writeHeader(body, .base_frame_id, u64, frame.frame_id);
            frame.base_frame_id = frame.frame_id;
            return expectBoth(error.InvalidFrameId, body.len);
        },
        .hidden_cursor_moved => {
            var cursor: Cursor = .{
                .appearance = frame.cursor.appearance,
            };
            if (smith.value(bool)) {
                cursor.x = smith.valueRangeAtMost(u16, 1, std.math.maxInt(u16));
            } else {
                cursor.y = smith.valueRangeAtMost(u16, 1, std.math.maxInt(u16));
            }

            moveCursor(body, frame, cursor);
            return expectBoth(error.InvalidCursor, body.len);
        },
        .cursor_outside => {
            var cursor: Cursor = .{
                .visible = true,
                .appearance = frame.cursor.appearance,
            };
            if (smith.value(bool)) {
                cursor.x = smith.valueRangeAtMost(u16, frame.cols, std.math.maxInt(u16));
            } else {
                cursor.y = smith.valueRangeAtMost(u16, frame.rows, std.math.maxInt(u16));
            }

            moveCursor(body, frame, cursor);
            return expectBoth(error.InvalidCursor, body.len);
        },
        .unknown_mouse_tracking => {
            writeHeader(body, .mouse_tracking, u8, smith.valueRangeAtMost(u8, @intFromEnum(keyinput.MouseTracking.any) + 1, std.math.maxInt(u8)));
            return expectDecode(error.InvalidMouseTracking, body.len);
        },
        .keyboard_flags_overflow => {
            writeHeader(body, .keyboard_flags, u8, smith.valueRangeAtMost(u8, std.math.maxInt(u5) + 1, std.math.maxInt(u8)));
            return expectDecode(error.InvalidKeyboardFlags, body.len);
        },
        .unknown_pointer_shape => {
            writeHeader(body, .pointer_shape, u8, smith.valueRangeAtMost(u8, @intFromEnum(frame_support.PointerShape.zoom_out) + 1, std.math.maxInt(u8)));
            return expectDecode(error.InvalidPointerShape, body.len);
        },
        .unknown_cursor_shape => {
            writeHeader(body, .cursor_shape, u8, smith.valueRangeAtMost(u8, @intFromEnum(Cursor.Shape.hollow) + 1, std.math.maxInt(u8)));
            return expectDecode(error.InvalidCursorShape, body.len);
        },
        .non_boolean => {
            writeHeader(body, boolean_fields[smith.index(boolean_fields.len)], u8, smith.valueRangeAtMost(u8, @as(u8, @intFromBool(true)) + 1, std.math.maxInt(u8)));
            return expectDecode(error.InvalidBoolean, body.len);
        },
        .short_history => {
            const total_rows = smith.valueRangeLessThan(u32, 0, frame.rows);
            writeHeader(body, .scroll_total_rows, u32, total_rows);
            frame.scroll.total_rows = total_rows;
            return expectBoth(error.InvalidScroll, body.len);
        },
        .scroll_past_history => {
            const max_offset = frame.scroll.total_rows - frame.rows;
            if (max_offset == std.math.maxInt(u32)) {
                return null;
            }

            const offset = smith.valueRangeAtMost(u32, max_offset + 1, std.math.maxInt(u32));
            writeHeader(body, .scroll_offset, u32, offset);
            frame.scroll.offset = offset;
            return expectBoth(error.InvalidScroll, body.len);
        },
        .too_many_spans => {
            writeHeader(body, .span_count, u16, smith.valueRangeAtMost(u16, frame_support.max_span_count + 1, std.math.maxInt(u16)));
            return expectDecode(error.TooManySpans, body.len);
        },
        .oversized_metadata => {
            const limit: u32 = @intCast(text_metadata_limits.capacity(frame.rows));
            writeHeader(body, .metadata_length, u32, smith.valueRangeAtMost(u32, limit + 1, std.math.maxInt(u32)));
            return expectDecode(error.TextMetadataTooLarge, body.len);
        },
        .snapshot_without_metadata => {
            if (!snapshot) {
                return null;
            }

            writeHeader(body, .metadata_length, u32, 0);
            return expectDecode(error.MissingSnapshotMetadata, body.len);
        },
        .empty_span => {
            if (spans.len == 0) {
                return null;
            }

            const index = smith.index(spans.len);
            writeSpan(body, index, .count, 0);
            spans[index].cells = spans[index].cells[0..0];
            return expectBoth(error.InvalidSpan, body.len);
        },
        .overlapping_span => {
            if (spans.len < 2) {
                return null;
            }

            const index = 1 + smith.index(spans.len - 1);
            const start = spans[index - 1].start + @as(u32, @intCast(smith.index(spans[index - 1].cells.len)));
            writeSpan(body, index, .start, start);
            spans[index].start = start;
            return expectBoth(error.InvalidSpan, body.len);
        },
        .span_past_screen => {
            if (spans.len == 0) {
                return null;
            }

            const count: u32 = @intCast(spans[last_span].cells.len);
            const start = smith.valueRangeAtMost(u32, grid - count + 1, std.math.maxInt(u32));
            writeSpan(body, last_span, .start, start);
            spans[last_span].start = start;
            return expectBoth(error.InvalidSpan, body.len);
        },
        .partial_snapshot => {
            if (!snapshot or grid < 2) {
                return null;
            }

            const count = smith.valueRangeLessThan(u32, 1, grid);
            writeSpan(body, 0, .count, count);
            spans[0].cells = spans[0].cells[0..count];
            return expectBoth(error.InvalidSnapshot, body.len);
        },
        .short_cells => {
            if (spans.len == 0) {
                return null;
            }

            const index = smith.index(spans.len);
            writeSpan(body, index, .encoded_length, readSpan(body, index, .count) - 1);
            return expectDecode(error.InvalidSpan, body.len);
        },
    }
}

fn expectBoth(err: anyerror, body_len: usize) FaultExpectation {
    return .{
        .decode = err,
        .encode = err,
        .body_len = body_len,
    };
}

fn expectDecode(err: anyerror, body_len: usize) FaultExpectation {
    return .{
        .decode = err,
        .encode = null,
        .body_len = body_len,
    };
}

fn encodeGeneratedFrame(_: void, smith: *Smith) anyerror!void {
    expectGeneratedFrame(smith) catch |err| std.debug.panic("generated frame property failed: {t}", .{err});
}

/// Generates a valid frame. It must encode to exactly the size its parts
/// add up to and decode to the same values; the same body with one rule
/// broken must be refused with that rule's error, by `encodeBody` too when
/// the rule is one a `Frame` can break.
fn expectGeneratedFrame(smith: *Smith) anyerror!void {
    var generated: GeneratedFrame = undefined;
    try generateFrame(smith, &generated);
    const frame = generated.frame;

    var buffer: [generated_body_capacity]u8 = undefined;
    var encoder = Encoder.init(&buffer);
    try frame_support.encodeBody(&encoder, frame);
    const body = buffer[0..encoder.index];

    var expected_length: usize = frame_support.body_header_size;
    if (frame.text_metadata) |metadata| {
        expected_length += metadata.encoded.len;
    } else if (frame.base_frame_id == 0) {
        expected_length += text_metadata_limits.header_size + frame.rows;
    }

    for (frame.spans) |span| {
        expected_length += frame_support.span_header_size + cellcodec.encodedCellsSize(span.cells, null);
    }

    try std.testing.expectEqual(expected_length, body.len);
    try expectDecodesTo(frame, body);

    var faulted_frame = frame;
    var faulted_spans = generated.spans;
    faulted_frame.spans = faulted_spans[0..frame.spans.len];
    const fault = smith.valueWeighted(FrameFault, &frame_fault_weights);
    const expectation = injectFault(smith, fault, body, &faulted_frame, faulted_spans[0..frame.spans.len]) orelse return;

    var decoder = Decoder.init(body[0..expectation.body_len]);
    try std.testing.expectError(expectation.decode, frame_support.decodeBody(&decoder));
    if (expectation.encode) |err| {
        var faulted_encoder = Encoder.init(&buffer);
        try std.testing.expectError(err, frame_support.encodeBody(&faulted_encoder, faulted_frame));
    }
}

/// A body the decoding target starts from and what it is: rejected with an
/// error, or structurally accepted with cells that do or do not read.
const FrameSeed = enum {
    snapshot,
    linked_snapshot,
    patch,
    empty_patch,
    unreadable_cells,
    truncated_snapshot,
    snapshot_without_metadata,
    overlapping_spans,
    empty_span,
    span_past_screen,
    oversized_metadata,
    cursor_outside,
};

const SeedOutcome = struct {
    structure: ?anyerror,
    cells_read: bool,
};

fn seedOutcome(seed: FrameSeed) SeedOutcome {
    return switch (seed) {
        .snapshot, .linked_snapshot, .patch, .empty_patch => .{
            .structure = null,
            .cells_read = true,
        },
        .unreadable_cells => .{
            .structure = null,
            .cells_read = false,
        },
        .truncated_snapshot => .{
            .structure = error.Truncated,
            .cells_read = false,
        },
        .snapshot_without_metadata => .{
            .structure = error.MissingSnapshotMetadata,
            .cells_read = false,
        },
        .overlapping_spans, .empty_span, .span_past_screen => .{
            .structure = error.InvalidSpan,
            .cells_read = false,
        },
        .oversized_metadata => .{
            .structure = error.TextMetadataTooLarge,
            .cells_read = false,
        },
        .cursor_outside => .{
            .structure = error.InvalidCursor,
            .cells_read = false,
        },
    };
}

fn textCell(text: []const u8, width: u8, style: Style) Cell {
    var cell: Cell = .{
        .len = @intCast(text.len),
        .width = width,
        .style = style,
    };
    @memcpy(cell.bytes[0..text.len], text);
    return cell;
}

const accent: Style = .{
    .fg = .rgb(.{ 1, 2, 3 }),
    .bg = .indexed(4),
    .flags = .{
        .bold = true,
        .underline = .curly,
    },
};

/// A 3x1 snapshot that sets every header field away from its default,
/// with a wide glyph and its spacer.
fn encodeSnapshotSeed(encoder: *Encoder) !void {
    const cells = [_]Cell{ textCell("a", 1, .{}), textCell("\u{1F600}", 2, accent), textCell("", 0, accent) };
    const spans = [_]Span{.{
        .start = 0,
        .cells = &cells,
    }};
    try frame_support.encodeBody(encoder, .{
        .pane_id = @enumFromInt(7),
        .frame_id = 3,
        .base_frame_id = 0,
        .cols = 3,
        .rows = 1,
        .cursor = .{
            .visible = true,
            .x = 2,
            .y = 0,
            .appearance = .{
                .shape = .bar,
                .blink = false,
            },
        },
        .mouse = .{
            .tracking = .button,
            .sgr = true,
        },
        .input_modes = .{
            .bracketed_paste = true,
            .kitty_keyboard_flags = std.math.maxInt(u5),
        },
        .pointer_shape = .text,
        .scroll = .{
            .total_rows = 5,
            .offset = 1,
        },
        .spans = &spans,
    });
}

/// A 4x2 snapshot or patch with a link run on its first row. The patch
/// changes cells 1-2 and 5 and replaces the metadata.
fn encodeLinkedSeed(encoder: *Encoder, snapshot: bool) !void {
    var scratch: [text_metadata_limits.capacity(2)]u8 = undefined;
    var builder = Builder.init(&scratch, 2);
    builder.setRow(0, .{
        .wrap = true,
        .hyperlinks = true,
    });
    builder.setRow(1, .{ .continuation = true });
    try builder.addRun(.{
        .start = 1,
        .len = 2,
        .link_index = try builder.addLink("https://example.test/a"),
    });

    const cells = [_]Cell{ textCell("h", 1, .{}), textCell("i", 1, accent), textCell("!", 1, accent), textCell(" ", 1, .{}) } ** 2;
    const snapshot_spans = [_]Span{.{
        .start = 0,
        .cells = &cells,
    }};
    const patch_spans = [_]Span{
        .{
            .start = 1,
            .cells = cells[1..3],
        },
        .{
            .start = 5,
            .cells = cells[5..6],
        },
    };
    try frame_support.encodeBody(encoder, .{
        .pane_id = @enumFromInt(4),
        .frame_id = 2,
        .base_frame_id = if (snapshot) 0 else 1,
        .cols = 4,
        .rows = 2,
        .text_metadata = builder.finish(.complete),
        .scroll = .{
            .total_rows = 2,
            .offset = 0,
        },
        .spans = if (snapshot) &snapshot_spans else &patch_spans,
    });
}

/// Writes `seed`'s body into `buffer`.
fn writeSeed(seed: FrameSeed, buffer: []u8) ![]u8 {
    var encoder = Encoder.init(buffer);
    switch (seed) {
        .snapshot, .truncated_snapshot, .cursor_outside => try encodeSnapshotSeed(&encoder),
        .linked_snapshot, .snapshot_without_metadata => try encodeLinkedSeed(&encoder, true),
        .patch, .unreadable_cells, .overlapping_spans, .empty_span, .span_past_screen, .oversized_metadata => try encodeLinkedSeed(&encoder, false),
        .empty_patch => try frame_support.encodeBody(&encoder, .{
            .pane_id = @enumFromInt(4),
            .frame_id = 9,
            .base_frame_id = 8,
            .cols = 4,
            .rows = 2,
            .scroll = .{
                .total_rows = 2,
                .offset = 0,
            },
            .spans = &.{},
        }),
    }

    const body = buffer[0..encoder.index];
    switch (seed) {
        .snapshot, .linked_snapshot, .patch, .empty_patch => {},
        .unreadable_cells => body[spanOffset(body, 0) + frame_support.span_header_size] &= ~cellcodec.style_changed_bit,
        .truncated_snapshot => return body[0 .. body.len - 1],
        .snapshot_without_metadata => writeHeader(body, .metadata_length, u32, 0),
        .overlapping_spans => writeSpan(body, 1, .start, 2),
        .empty_span => writeSpan(body, 0, .count, 0),
        .span_past_screen => writeSpan(body, 1, .start, 8),
        .oversized_metadata => writeHeader(body, .metadata_length, u32, @intCast(text_metadata_limits.capacity(2) + 1)),
        .cursor_outside => writeHeader(body, .cursor_x, u16, 3),
    }

    return body;
}

const seed_count = @typeInfo(FrameSeed).@"enum".fields.len;
/// Room for each seed's `Smith` slice length and body.
const seed_capacity = @sizeOf(u32) + 512;

/// The seeds in `std.testing.Smith` input form: one `slice` call reads a
/// little-endian u32 length and then that many bytes. A crash the fuzzer
/// saves has the same form, so it can join this corpus as it is.
fn writeCorpus(storage: *[seed_count][seed_capacity]u8, entries: *[seed_count][]const u8) !void {
    for (storage, entries, 0..) |*slot, *entry, index| {
        const body = try writeSeed(@enumFromInt(index), slot[@sizeOf(u32)..]);
        std.mem.writeInt(u32, slot[0..@sizeOf(u32)], @intCast(body.len), .little);
        entry.* = slot[0 .. @sizeOf(u32) + body.len];
    }
}

test "every frame body fuzz seed reaches its decoder outcome" {
    var storage: [seed_count][seed_capacity]u8 = undefined;
    var entries: [seed_count][]const u8 = undefined;
    try writeCorpus(&storage, &entries);

    for (entries, 0..) |entry, index| {
        const seed: FrameSeed = @enumFromInt(index);
        const outcome = seedOutcome(seed);

        var smith: Smith = .{ .in = entry };
        var buffer: [payload_capacity]u8 = undefined;
        const payload = buffer[0..smith.slice(&buffer)];
        try std.testing.expectEqualSlices(u8, entry[@sizeOf(u32)..], payload);

        var decoder = Decoder.init(payload);
        const view = frame_support.decodeBody(&decoder) catch |err| {
            const rejection: ?anyerror = err;
            try std.testing.expectEqual(outcome.structure, rejection);
            continue;
        };

        try std.testing.expectEqual(null, outcome.structure);
        try std.testing.expectEqual(payload.len, decoder.index);
        var cells: [max_payload_cells]Cell = undefined;
        var spans: [max_payload_spans]Span = undefined;
        try std.testing.expectEqual(outcome.cells_read, try expectAcceptedStructure(view, payload, &cells, &spans));
    }
}

test "fuzz frame body decoding" {
    var storage: [seed_count][seed_capacity]u8 = undefined;
    var entries: [seed_count][]const u8 = undefined;
    try writeCorpus(&storage, &entries);

    try std.testing.fuzz({}, decodeFuzzedBody, .{
        .corpus = &entries,
    });
}

test "fuzz generated frames" {
    try std.testing.fuzz({}, encodeGeneratedFrame, .{});
}

/// Columns and rows whose product is exactly `frame_support.max_cell_count`,
/// both within a u16.
const largest_screen: [2]u16 = screen: {
    @setEvalBranchQuota(1_000_000);
    const cells = frame_support.max_cell_count;
    var cols: u32 = std.math.divCeil(u32, cells, std.math.maxInt(u16)) catch unreachable;
    while (cells % cols != 0) : (cols += 1) {}

    std.debug.assert(cols <= std.math.maxInt(u16));
    break :screen .{ @intCast(cols), @intCast(cells / cols) };
};

fn emptyPatch(cols: u16, rows: u16) Frame {
    return .{
        .pane_id = @enumFromInt(1),
        .frame_id = 2,
        .base_frame_id = 1,
        .cols = cols,
        .rows = rows,
        .scroll = .{
            .total_rows = rows,
            .offset = 0,
        },
        .spans = &.{},
    };
}

test "the largest screen fits a frame and one more row does not" {
    var buffer: [frame_support.body_header_size]u8 = undefined;
    var encoder = Encoder.init(&buffer);
    const largest = emptyPatch(largest_screen[0], largest_screen[1]);
    try frame_support.encodeBody(&encoder, largest);
    try expectDecodesTo(largest, encoder.finish());

    const taller = emptyPatch(largest_screen[0], largest_screen[1] + 1);
    encoder = Encoder.init(&buffer);
    try std.testing.expectError(error.ScreenTooLarge, frame_support.encodeBody(&encoder, taller));

    writeHeader(&buffer, .rows, u16, taller.rows);
    writeHeader(&buffer, .scroll_total_rows, u32, taller.rows);
    var decoder = Decoder.init(&buffer);
    try std.testing.expectError(error.ScreenTooLarge, frame_support.decodeBody(&decoder));
}

test "a body of the maximum size is structurally accepted though its cells are not" {
    const buffer = try std.testing.allocator.alloc(u8, frame_support.max_body_size + 1);
    defer std.testing.allocator.free(buffer);
    @memset(buffer, 0);

    var encoder = Encoder.init(buffer);
    try frame_support.encodeBody(&encoder, emptyPatch(std.math.maxInt(u16), 1));
    writeHeader(buffer, .span_count, u16, 1);
    const cells_length = frame_support.max_body_size - frame_support.body_header_size - frame_support.span_header_size;
    writeSpan(buffer, 0, .count, 1);
    writeSpan(buffer, 0, .encoded_length, cells_length);

    var decoder = Decoder.init(buffer[0..frame_support.max_body_size]);
    const view = try frame_support.decodeBody(&decoder);
    try std.testing.expectEqual(frame_support.max_body_size, decoder.index);
    var spans = view.spans();
    var cells = (try spans.next()).?.cells();
    try std.testing.expectError(error.InvalidCell, cells.next());

    writeSpan(buffer, 0, .encoded_length, cells_length + 1);
    decoder = Decoder.init(buffer);
    try std.testing.expectError(error.FrameTooLarge, frame_support.decodeBody(&decoder));
}

test "the most spans a frame allows decode and one more is refused" {
    const span_count = frame_support.max_span_count + 1;
    const cell = [_]Cell{.{}};
    const spans = try std.testing.allocator.alloc(Span, span_count);
    defer std.testing.allocator.free(spans);
    for (spans, 0..) |*span, index| {
        span.* = .{
            .start = @intCast(2 * index),
            .cells = &cell,
        };
    }

    const buffer = try std.testing.allocator.alloc(u8, frame_support.body_header_size + span_count * (frame_support.span_header_size + cellcodec.max_cell_size));
    defer std.testing.allocator.free(buffer);
    var frame = emptyPatch(2 * span_count, 1);
    frame.spans = spans;
    var encoder = Encoder.init(buffer);
    try std.testing.expectError(error.TooManySpans, frame_support.encodeBody(&encoder, frame));

    frame.spans = spans[0..frame_support.max_span_count];
    encoder = Encoder.init(buffer);
    try frame_support.encodeBody(&encoder, frame);
    const body = buffer[0..encoder.index];
    try expectDecodesTo(frame, body);

    writeHeader(body, .span_count, u16, span_count);
    var decoder = Decoder.init(body);
    try std.testing.expectError(error.TooManySpans, frame_support.decodeBody(&decoder));
}
