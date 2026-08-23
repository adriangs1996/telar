//! Applies protocol frames to the client's terminal screen.

const std = @import("std");
const core = @import("telar-core");
const term = @import("term.zig");

const schema = core.schema;

pub const Applied = struct {
    spans: u64 = 0,
    cells: u64 = 0,
};

pub fn applyBuffer(
    buffer: *core.ui.Buffer,
    cursor: *schema.frame.Cursor,
    frame: schema.frame.FrameView,
) !Applied {
    if (frame.base_frame_id == 0 and
        (buffer.w != frame.cols or buffer.h != frame.rows))
    {
        try buffer.resize(frame.cols, frame.rows);
    } else if (buffer.w != frame.cols or buffer.h != frame.rows) {
        return error.PatchSizeMismatch;
    }

    var applied: Applied = .{};
    var spans = frame.spans();
    while (spans.next()) |span| {
        const start: usize = span.start;
        const count: usize = span.cell_count;
        const end = std.math.add(usize, start, count) catch return error.PatchOutOfBounds;
        if (count == 0 or end > buffer.cells.len) return error.PatchOutOfBounds;
        var cells = span.cells();
        var index = start;
        while (cells.next()) |cell| : (index += 1) {
            buffer.cells[index] = cell;
            applied.cells += 1;
        }
        std.debug.assert(index == end);
        applied.spans += 1;
    }
    cursor.* = frame.cursor;
    return applied;
}

pub fn apply(screen: *term.Screen, frame: schema.frame.FrameView) !Applied {
    if (frame.base_frame_id == 0 and
        !screen.sizeMatches(frame.cols, frame.rows))
    {
        try screen.resize(frame.cols, frame.rows);
    } else if (!screen.sizeMatches(frame.cols, frame.rows)) {
        return error.PatchSizeMismatch;
    }

    var applied: Applied = .{};
    var spans = frame.spans();
    while (spans.next()) |span| {
        applied.spans += 1;
        const target = try screen.patchCells(span.start, span.cell_count);
        var cells = span.cells();
        var index: usize = 0;
        while (cells.next()) |cell| : (index += 1) {
            target[index] = cell;
            applied.cells += 1;
        }
        std.debug.assert(index == target.len);
    }
    screen.cursor = if (frame.cursor.visible)
        .{ .x = frame.cursor.x, .y = frame.cursor.y }
    else
        null;
    return applied;
}

test "a patch updates the screen and reports its work" {
    var screen = try term.Screen.init(std.testing.allocator, 4, 2);
    defer screen.deinit();

    const cells = [_]core.ui.Cell{
        .{ .bytes = [_]u8{'x'} ++ [_]u8{0} ** (core.ui.Cell.max_bytes - 1) },
        .{ .bytes = [_]u8{'y'} ++ [_]u8{0} ** (core.ui.Cell.max_bytes - 1) },
    };
    const spans = [_]schema.frame.Span{.{ .start = 2, .cells = &cells }};
    var encoded: [256]u8 = undefined;
    const payload = try schema.encodePaneFrame(&encoded, .{
        .pane_id = @enumFromInt(1),
        .frame_id = 2,
        .base_frame_id = 1,
        .cols = 4,
        .rows = 2,
        .spans = &spans,
    });
    const decoded = (try schema.decodeServer(payload)).pane_frame;

    const applied = try apply(&screen, decoded);
    try std.testing.expectEqual(@as(u64, 1), applied.spans);
    try std.testing.expectEqual(@as(u64, 2), applied.cells);
    try std.testing.expectEqualStrings("x", screen.back.cells[2].text());
    try std.testing.expectEqualStrings("y", screen.back.cells[3].text());
}

test "a patch cannot silently resize the client screen" {
    var screen = try term.Screen.init(std.testing.allocator, 4, 2);
    defer screen.deinit();

    const cells = [_]core.ui.Cell{.{}};
    const spans = [_]schema.frame.Span{.{ .start = 0, .cells = &cells }};
    var encoded: [256]u8 = undefined;
    const payload = try schema.encodePaneFrame(&encoded, .{
        .pane_id = @enumFromInt(1),
        .frame_id = 2,
        .base_frame_id = 1,
        .cols = 5,
        .rows = 2,
        .spans = &spans,
    });
    const decoded = (try schema.decodeServer(payload)).pane_frame;

    try std.testing.expectError(error.PatchSizeMismatch, apply(&screen, decoded));
}
