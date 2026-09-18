const std = @import("std");
const Fixture = @import("ConversationFixture.zig");
const Text = @import("../widgets/MessageText.zig");
const TablePaint = @import("../widgets/MessageTablePaint.zig");
const Registry = @import("../widgets/interaction/Registry.zig");
const owner: @import("../widgets/MessageLayoutOwner.zig") = .{ .pane_id = @enumFromInt(1), .attachment_generation = 3, .pane_generation = 5, .snapshot_revision = 7, .item_identity = 11, .section = .body, .source_offset = 120 };

fn message(source: []const u8) Text {
    return .{ .bounds = .{ .x = 10, .y = 20, .width = 650, .height = 700 }, .viewport = .{ .x = 10, .y = 20, .width = 650, .height = 700 }, .text = source, .owner = owner };
}

fn render(fixture: *Fixture, text: Text) !*const Registry {
    fixture.quads.clear();
    _ = fixture.state.?.dispatcher.begin();
    var canvas = fixture.canvas();
    try text.draw(&canvas);
    fixture.state.?.dispatcher.seal();
    fixture.state.?.dispatcher.present(true);
    return fixture.state.?.dispatcher.maps.presented();
}

test "table columns align inline links and preserve their source coordinates" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.enableCache();
    const text = message("| Left | Center | Right |\n| :--- | :---: | ---: |\n| [a](one) | [b](two) | [c](three) |\n| [long](four) | [long](five) | [long](six) |");
    const registry = try render(&fixture, text);
    try std.testing.expectEqual(@as(usize, 6), registry.len);
    const targets = registry.targets[0..6];
    try std.testing.expectApproxEqAbs(targets[0].bounds.x, targets[3].bounds.x, 0.01);
    try std.testing.expectApproxEqAbs(targets[1].bounds.x + targets[1].bounds.width / 2, targets[4].bounds.x + targets[4].bounds.width / 2, 0.01);
    try std.testing.expectApproxEqAbs(targets[2].bounds.x + targets[2].bounds.width, targets[5].bounds.x + targets[5].bounds.width, 0.01);
    try std.testing.expect(targets[0].bounds.y == targets[1].bounds.y and targets[1].bounds.y == targets[2].bounds.y);
    try std.testing.expect(targets[3].bounds.y > targets[0].bounds.y);
    for (targets, [_][]const u8{ "one", "two", "three", "four", "five", "six" }) |target, destination| {
        const link = target.action.message_link;
        try std.testing.expectEqualDeep(owner, link.owner);
        try std.testing.expectEqualStrings(destination, text.text[link.destination_offset - owner.source_offset ..][0..link.destination_len]);
    }
}

test "tables wrap long headers and Unicode cells and share measured and painted height" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.enableCache();
    var text = message("| Precio final de la visita | Ingreso sin el IVA supuesto | Resto tras los 43,33 € de costes directos |\n| ---: | ---: | ---: |\n| 50 € | 41,32 € | **−2,01 €** |\n| 60 € | 49,59 € | **6,25 €** |\n| 75 € | 61,98 € | **18,65 €** |\n| 85 € | 70,25 € | **26,91 €** |\n| 95 € | 78,51 € | **35,18 €** |");
    var canvas = fixture.canvas();
    const wide = try text.measure(&canvas);
    text.bounds.width = 270;
    text.viewport.width = 270;
    const narrow = try text.measure(&canvas);
    try std.testing.expect(narrow > wide);
    const table: TablePaint = .{ .bounds = text.bounds, .viewport = text.viewport, .table = @import("../widgets/MessageTable.zig").parse(text.text).?, .owner = text.owner, .source_start = @intFromPtr(text.text.ptr) };
    try std.testing.expectApproxEqAbs(narrow, try table.layout(&canvas, true), 0.01);
    _ = try render(&fixture, text);
    for (fixture.quads.items()) |quad| {
        try std.testing.expect(quad.x >= text.viewport.x and quad.y >= text.viewport.y);
        try std.testing.expect(quad.x + quad.width <= text.viewport.x + text.viewport.width + 0.01);
        try std.testing.expect(quad.y + quad.height <= text.viewport.y + text.viewport.height + 0.01);
    }
}

test "table viewport clipping bounds offscreen decoration work and link targets" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.enableCache();
    var text = message("A | B\n--- | ---\n" ++ "[x](url) | 50 €\n" ** 800);
    var canvas = fixture.canvas();
    const height = try text.measure(&canvas);
    text.bounds.y = 80 - height;
    text.viewport.height = 60;
    try fixture.quads.quads.ensureTotalCapacity(std.testing.allocator, 100);
    fixture.quads.limit = 100;
    const targets = try render(&fixture, text);
    try std.testing.expect(targets.len > 0 and targets.len <= 2);
    try std.testing.expect(fixture.quads.items().len < 100);
    for (targets.targets[0..targets.len]) |target| {
        try std.testing.expect(target.bounds.y >= text.viewport.y);
        try std.testing.expect(target.bounds.y + target.bounds.height <= 80.01);
    }
}

test "warm table layout and drawing allocate nothing" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.enableCache();
    const text = message("| Name | Price |\n| --- | ---: |\n| [Visit](https://example.test) | **50 €** |\n| Café | 60 € |");
    _ = try render(&fixture, text);
    _ = try render(&fixture, text);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    fixture.atlas.allocator = failing.allocator();
    fixture.quads.allocator = failing.allocator();
    defer fixture.atlas.allocator = std.testing.allocator;
    defer fixture.quads.allocator = std.testing.allocator;
    var canvas = fixture.canvas();
    _ = try text.measure(&canvas);
    _ = try render(&fixture, text);
    try std.testing.expectEqual(@as(usize, 0), failing.allocated_bytes);
}

test "wrapped right aligned table links align every visual line including the last" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.enableCache();
    var text = message("| Right |\n| ---: |\n| [abcdefghijklmnoabcdefghijklmnop](url) |");
    text.bounds.width = 95;
    text.viewport.width = 95;
    const registry = try render(&fixture, text);
    try std.testing.expect(registry.len >= 3);
    for (registry.targets[0..registry.len]) |target| {
        try std.testing.expectApproxEqAbs(@as(f32, 93), target.bounds.x + target.bounds.width, 0.01);
    }
}

test "native table selection follows cells in source order and copies visible text" {
    const Reader = @import("ThreadSelectionFixture.zig");
    var fixture = try Reader.init();
    defer fixture.deinit();
    try fixture.messages(&.{ "Compare the visits.", "| Name | Price |\n| --- | ---: |\n| **Visit** | 50 € |\n| `a\\|b` | 60 € |\n\nAfter" });
    try fixture.publish();
    try fixture.drag(.{ try fixture.point(2, "Name"), try fixture.point(2, "After") });
    try fixture.send(.{ .key = .{ .code = .{ .char = .init("c") }, .mods = .{ .super = true } } });
    const request = try fixture.clipboard();
    try std.testing.expectEqualStrings("Name\tPrice\nVisit\t50 €\na|b\t60 €\n\n", request.text.?[0..request.len]);
}
