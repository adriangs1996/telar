//! Applies protocol frames to the client's terminal screen.

const ScreenType = @import("Screen.zig");
const FrameViewType = @import("telar-core").FrameView;
const Applied = @import("telar-client").Applied;
const std = @import("std");
const CellType = @import("telar-core").Cell;
const SpanType = @import("telar-core").Span;
const encodePaneFrame_module = @import("telar-core").encodePaneFrame;
const decodeServer_module = @import("telar-core").decodeServer;

pub fn apply(screen: *ScreenType, frame: FrameViewType) !Applied {
    if (frame.base_frame_id == 0 and
        !screen.sizeMatches(frame.cols, frame.rows))
    {
        try screen.resize(frame.cols, frame.rows);
    } else if (!screen.sizeMatches(frame.cols, frame.rows)) {
        return error.PatchSizeMismatch;
    }

    var applied: Applied = .{};
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

    const cells = [_]CellType{
        .{ .bytes = [_]u8{'x'} ++ [_]u8{0} ** (CellType.max_bytes - 1) },
        .{ .bytes = [_]u8{'y'} ++ [_]u8{0} ** (CellType.max_bytes - 1) },
    };
    const spans = [_]SpanType{.{ .start = 2, .cells = &cells }};
    var encoded: [256]u8 = undefined;
    const payload = try encodePaneFrame_module(&encoded, .{
        .pane_id = @enumFromInt(1),
        .frame_id = 2,
        .base_frame_id = 1,
        .cols = 4,
        .rows = 2,
        .scroll = .{ .total_rows = 2, .offset = 0 },
        .spans = &spans,
    });
    const decoded = (try decodeServer_module(payload)).pane_frame;

    const applied = try apply(&screen, decoded);
    try std.testing.expectEqual(@as(u64, 1), applied.spans);
    try std.testing.expectEqual(@as(u64, 2), applied.cells);
    try std.testing.expectEqualStrings("x", screen.back.cells[2].text());
    try std.testing.expectEqualStrings("y", screen.back.cells[3].text());
}

test "a patch cannot silently resize the client screen" {
    var screen = try ScreenType.init(std.testing.allocator, 4, 2);
    defer screen.deinit();

    const cells = [_]CellType{.{}};
    const spans = [_]SpanType{.{ .start = 0, .cells = &cells }};
    var encoded: [256]u8 = undefined;
    const payload = try encodePaneFrame_module(&encoded, .{
        .pane_id = @enumFromInt(1),
        .frame_id = 2,
        .base_frame_id = 1,
        .cols = 5,
        .rows = 2,
        .scroll = .{ .total_rows = 2, .offset = 0 },
        .spans = &spans,
    });
    const decoded = (try decodeServer_module(payload)).pane_frame;

    try std.testing.expectError(error.PatchSizeMismatch, apply(&screen, decoded));
}
