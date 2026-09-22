//! Applies protocol frames to the client's terminal screen.

const data = @import("model");
const core = @import("telar-core");
const client = @import("telar-client");
const ScreenType = @import("Screen.zig");
const std = @import("std");

pub fn apply(screen: *ScreenType, frame: core.FrameView) !data.Applied {
    if (frame.base_frame_id == 0 and
        !screen.sizeMatches(frame.cols, frame.rows))
    {
        try screen.resize(frame.cols, frame.rows);
    } else if (!screen.sizeMatches(frame.cols, frame.rows)) {
        return error.PatchSizeMismatch;
    }

    var applied: data.Applied = .{};
    var spans = frame.spans();
    while (try spans.next()) |span| {
        applied.spans += 1;
        const target = try screen.patchCells(span.start, span.cell_count);
        var cells = span.cells();
        var index: usize = 0;
        while (try cells.next()) |cell| : (index += 1) {
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
    var screen = try ScreenType.init(std.testing.allocator, 4, 2);
    defer screen.deinit();

    const cells = [_]core.Cell{
        .{ .bytes = [_]u8{'x'} ++ [_]u8{0} ** (core.Cell.max_bytes - 1) },
        .{ .bytes = [_]u8{'y'} ++ [_]u8{0} ** (core.Cell.max_bytes - 1) },
    };
    const spans = [_]core.Span{.{ .start = 2, .cells = &cells }};
    var encoded: [256]u8 = undefined;
    const payload = try core.encodePaneFrame(&encoded, .{
        .pane_id = @enumFromInt(1),
        .frame_id = 2,
        .base_frame_id = 1,
        .cols = 4,
        .rows = 2,
        .scroll = .{ .total_rows = 2, .offset = 0 },
        .spans = &spans,
    });
    const decoded = (try core.decodeServer(payload)).pane_frame;

    const applied = try apply(&screen, decoded);
    try std.testing.expectEqual(@as(u64, 1), applied.spans);
    try std.testing.expectEqual(@as(u64, 2), applied.cells);
    try std.testing.expectEqualStrings("x", screen.back.cells[2].text());
    try std.testing.expectEqualStrings("y", screen.back.cells[3].text());
}

test "a patch cannot silently resize the client screen" {
    var screen = try ScreenType.init(std.testing.allocator, 4, 2);
    defer screen.deinit();

    const cells = [_]core.Cell{.{}};
    const spans = [_]core.Span{.{ .start = 0, .cells = &cells }};
    var encoded: [256]u8 = undefined;
    const payload = try core.encodePaneFrame(&encoded, .{
        .pane_id = @enumFromInt(1),
        .frame_id = 2,
        .base_frame_id = 1,
        .cols = 5,
        .rows = 2,
        .scroll = .{ .total_rows = 2, .offset = 0 },
        .spans = &spans,
    });
    const decoded = (try core.decodeServer(payload)).pane_frame;

    try std.testing.expectError(error.PatchSizeMismatch, apply(&screen, decoded));
}
