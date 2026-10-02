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
    const row: HistoryRow = .{ .projection = &projection, .bounds = .{ .x = 20, .y = 20, .width = 700, .height = 48 }, .index = 0, .row_height = 48 };
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

test "an open history card wraps a long command completely and stays warm" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    const history = &fixture.model.history_palette;
    try history.prepare(std.testing.allocator);
    const long = "printf '%s\\n' " ++ "alpha-beta-gamma " ** 24 ++ "| sort";
    const script = "for word in uno dos tres; do\n  printf '%s\\n' \"$word · añadir café 日本語\"\ndone";
    try std.testing.expect(history.beginPageRequest(1, .global));
    try std.testing.expect(history.acceptPageResult(.{
        .request_id = 1,
        .entries = &.{
            .{ .id = 9, .pane_id = @enumFromInt(2), .started_at_ms = 1000, .duration_ns = 1000000, .exit_code = 1, .status = .completed, .command = long, .cwd = "/work/telar", .workspace_path = "/work" },
            .{ .id = 8, .pane_id = @enumFromInt(2), .started_at_ms = 900, .duration_ns = 1000000, .exit_code = 0, .status = .completed, .command = script, .cwd = "/work/telar", .workspace_path = "/work" },
        },
        .snapshot_id = 9,
        .has_more = false,
        .now_ms = 2000,
    }));
    fixture.model.name_prompt.begin(.history_palette);
    const projection = fixture.projection();
    var canvas = fixture.canvas();
    const cell: f32 = @floatFromInt(canvas.metrics.cell_height);
    const closed: HistoryRow = .{ .projection = &projection, .bounds = .{ .x = 20, .y = 20, .width = 700, .height = 34 }, .index = 0, .row_height = 34 };
    var card = closed;
    card.open = 1;
    card.highlight = 1;
    card.selected = true;
    const one_line = blk: {
        var short = card;
        short.bounds.width = 4000;
        break :blk try short.cardHeight(&canvas);
    };
    const wrapped = try card.cardHeight(&canvas);
    const lines = @round((wrapped - one_line) / cell) + 1;
    const columns = @floor((700 - 16 - 40 - 12) / @as(f32, @floatFromInt(canvas.metrics.cell_width)));
    try std.testing.expect(lines >= @ceil(@as(f32, @floatFromInt(long.len)) / columns));
    try std.testing.expect(lines <= @as(f32, @floatFromInt(HistoryRow.max_lines)));

    // The three lines of a multi-line command each take one line of the card.
    card.index = 1;
    card.bounds.width = 4000;
    try std.testing.expectEqual(one_line + 2 * cell, try card.cardHeight(&canvas));

    // A card past its limit keeps the limit and says the rest is elsewhere.
    card.index = 0;
    card.bounds.width = 700;
    card.line_limit = 2;
    try std.testing.expectEqual(one_line + cell, try card.cardHeight(&canvas));

    card.line_limit = HistoryRow.max_lines;
    card.bounds.height = wrapped;
    try closed.draw(&canvas);
    const closed_quads = fixture.renderer.quads.items().len;
    fixture.renderer.quads.clear();
    try card.draw(&canvas);
    const count = fixture.renderer.quads.items().len;
    try std.testing.expect(count > closed_quads);
    for (fixture.renderer.quads.items()) |quad| {
        try std.testing.expect(quad.y >= card.bounds.y - 0.001 and quad.y + quad.height <= card.bounds.y + wrapped + 0.001);
    }

    const version = fixture.renderer.atlas.?.version;
    const calls = fixture.renderer.atlas.?.shape_calls;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    fixture.renderer.atlas.?.allocator = failing.allocator();
    fixture.renderer.quads.allocator = failing.allocator();
    defer fixture.renderer.atlas.?.allocator = std.testing.allocator;
    defer fixture.renderer.quads.allocator = std.testing.allocator;
    for (0..8) |_| {
        fixture.renderer.quads.clear();
        try card.draw(&canvas);
        try std.testing.expectEqual(count, fixture.renderer.quads.items().len);
    }

    try std.testing.expectEqual(calls, fixture.renderer.atlas.?.shape_calls);
    try std.testing.expectEqual(version, fixture.renderer.atlas.?.version);
    try std.testing.expectEqual(@as(usize, 0), failing.allocated_bytes);
}
