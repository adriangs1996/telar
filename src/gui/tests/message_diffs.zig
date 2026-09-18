const std = @import("std");
const Fixture = @import("ConversationFixture.zig");
const Text = @import("../widgets/MessageText.zig");
const Paint = @import("../widgets/DiffPaint.zig");

const source = "Updated /project/src/runtime.zig\n@@ -1409,3 +1409,4 @@\n const pane = workspace.find(id);\n-try pane.scroll(100);\n+try pane.scroll(0);\n+try pane.render(\"Café 界 🙂\");\n return pane;\nAdded src/new.zig\n@@ -0,0 +1 @@\n+const ready = true;\n";

fn message(text: []const u8) Text {
    return .{ .bounds = .{ .x = 10, .y = 20, .width = 650, .height = 700 }, .viewport = .{ .x = 10, .y = 20, .width = 650, .height = 700 }, .text = text, .code = true, .diff = true, .owner = .{ .pane_id = @enumFromInt(1), .attachment_generation = 3, .pane_generation = 5, .snapshot_revision = 7, .item_identity = 11, .section = .body, .source_offset = 120 } };
}

test "diffs share measured and painted height and wrap inside narrow panes" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var canvas = fixture.canvas();
    var text = message(source);
    const wide = try text.measure(&canvas);
    for ([_]f32{ 650, 270, 95, 12 }) |width| {
        text.bounds.width = width;
        text.viewport.width = width;
        fixture.quads.clear();
        const measured = try text.measure(&canvas);
        var diff: Paint = .{ .canvas = &canvas, .bounds = text.bounds, .viewport = text.viewport, .text = text.text, .source_start = @intFromPtr(text.text.ptr), .paint = true };
        try std.testing.expectEqual(measured, try diff.layout());
        try std.testing.expectEqual(measured, try diff.layout());
        if (width < 100) {
            try std.testing.expect(measured > wide);
        }

        for (fixture.quads.items()) |quad| {
            try std.testing.expect(quad.x >= text.viewport.x and quad.y >= text.viewport.y);
            try std.testing.expect(quad.x + quad.width <= text.viewport.x + text.viewport.width + 0.01);
            try std.testing.expect(quad.y + quad.height <= text.viewport.y + text.viewport.height + 0.01);
        }
    }
}

test "diff decorations and wrapped text retain geometry only for the visible viewport" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var canvas = fixture.canvas();
    var text = message("Updated large.zig\n@@ -0,0 +1,2000 @@\n" ++ "+const x = 1;\n" ** 2000);
    const height = try text.measure(&canvas);
    text.bounds.y = 80 - height;
    text.viewport.height = 60;
    try fixture.quads.quads.ensureTotalCapacity(std.testing.allocator, 160);
    fixture.quads.limit = 160;
    try text.draw(&canvas);
    try std.testing.expect(fixture.quads.items().len > 0 and fixture.quads.items().len < 160);
}

test "diff source coordinates exclude generated gutters and preserve Unicode through wrapping" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.enableCache();
    const store = try fixture.state.?.threadText(std.testing.allocator);
    const snapshot = try std.testing.allocator.create(@import("telar-core").AgentThreadSnapshot);
    defer std.testing.allocator.destroy(snapshot);
    snapshot.* = .{ .pane_id = @enumFromInt(1), .pane_generation = 5, .revision = 7, .item_count = 1, .text_len = source.len };
    @memcpy(snapshot.text_storage[0..source.len], source);
    snapshot.item_storage[0] = .{ .identity = 11, .role = .tool, .kind = .file_change, .text_len = source.len };
    var text = message(source);
    text.bounds.width = 230;
    text.viewport.width = 230;
    text.owner.?.source_offset = 0;
    const view: @import("../widgets/ThreadItemView.zig") = .{ .thread = .{ .pane_id = snapshot.pane_id, .attachment_generation = 3, .agent = null, .composer = "", .transcript = snapshot }, .item = &snapshot.item_storage[0], .bounds = text.bounds, .viewport = text.viewport, .expanded = true };
    const geometry = store.maps.preparing();
    geometry.addRow(view, 0);
    var canvas = fixture.canvas();
    try text.draw(&canvas);
    try std.testing.expect(geometry.fragment_count > 0);
    for (geometry.fragments[0..geometry.fragment_count]) |fragment| {
        const content = source[fragment.offset..][0..fragment.len];
        try std.testing.expect(std.unicode.utf8ValidateSlice(content));
        try std.testing.expect(std.mem.indexOfScalar(u8, content, '\n') == null);
        try std.testing.expect(!std.mem.startsWith(u8, content, "@@"));
        try std.testing.expect(!std.mem.startsWith(u8, content, "+"));
        try std.testing.expect(!std.mem.startsWith(u8, content, "-"));
        try std.testing.expect(fragment.bounds.x > text.bounds.x);
    }
}

test "warm diff measurement and drawing allocate nothing and fenced patches reuse the painter" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var canvas = fixture.canvas();
    var text = message("```patch\n" ++ source ++ "```\n");
    text.code = false;
    text.diff = false;
    try text.draw(&canvas);
    fixture.quads.clear();
    try text.draw(&canvas);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    fixture.atlas.allocator = failing.allocator();
    fixture.quads.allocator = failing.allocator();
    defer fixture.atlas.allocator = std.testing.allocator;
    defer fixture.quads.allocator = std.testing.allocator;
    const plain = try message(source).measure(&canvas);
    try std.testing.expectEqual(plain, try text.measure(&canvas));
    fixture.quads.clear();
    try text.draw(&canvas);
    try std.testing.expectEqual(@as(usize, 0), failing.allocated_bytes);
}
