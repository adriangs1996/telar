const std = @import("std");
const Fixture = @import("OverlayFixture.zig");
const HistoryRow = @import("../widgets/overlays/HistoryRow.zig");

test "native history rows reuse warm shaping for long directories and maximum metadata" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    const history = &fixture.model.history_palette;
    try history.prepare(std.testing.allocator);
    try std.testing.expect(history.beginPageRequest(1, .global));
    try std.testing.expect(history.acceptPageResult(.{
        .request_id = 1,
        .entries = &.{.{ .id = 9, .pane_id = @enumFromInt(2), .started_at_ms = 0, .duration_ns = std.math.maxInt(i64), .exit_code = 0, .status = .completed, .command = "zig build", .cwd = "/work/" ++ "unicode-e\u{301}-directory/" ** 6 ++ "telar", .workspace_path = "/work" }},
        .snapshot_id = 9,
        .has_more = false,
        .now_ms = std.math.maxInt(i64),
    }));
    fixture.model.name_prompt.begin(.history_palette);
    const projection = fixture.projection();
    var canvas = fixture.canvas();
    const row: HistoryRow = .{ .projection = &projection, .bounds = .{ .x = 20, .y = 20, .width = 700, .height = 48 }, .index = 0, .selected = true };
    try row.draw(&canvas);
    const count = fixture.renderer.quads.items().len;
    const version = fixture.renderer.atlas.?.version;
    const calls = fixture.renderer.atlas.?.shape_calls;

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    fixture.renderer.atlas.?.allocator = failing.allocator();
    fixture.renderer.quads.allocator = failing.allocator();
    defer fixture.renderer.atlas.?.allocator = std.testing.allocator;
    defer fixture.renderer.quads.allocator = std.testing.allocator;
    for (0..8) |_| {
        fixture.renderer.quads.clear();
        try row.draw(&canvas);
        try std.testing.expectEqual(count, fixture.renderer.quads.items().len);
    }

    try std.testing.expectEqual(calls, fixture.renderer.atlas.?.shape_calls);
    try std.testing.expectEqual(version, fixture.renderer.atlas.?.version);
    try std.testing.expectEqual(@as(usize, 0), failing.allocated_bytes);
    try std.testing.expectEqualStrings("/work/" ++ "unicode-e\u{301}-directory/" ** 6 ++ "telar", history.slice()[0].cwdSlice());
    try std.testing.expectEqual(@as(u16, 0), projection.prompt.?.selection());
}
