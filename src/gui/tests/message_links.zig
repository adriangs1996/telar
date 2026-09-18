const std = @import("std");
const Fixture = @import("ConversationFixture.zig");
const Text = @import("../widgets/MessageText.zig");
const Target = @import("../widgets/interaction/Target.zig");
const Registry = @import("../widgets/interaction/Registry.zig");
const owner: @import("../widgets/MessageLayoutOwner.zig") = .{ .pane_id = @enumFromInt(1), .attachment_generation = 3, .pane_generation = 5, .snapshot_revision = 7, .item_identity = 11, .section = .body, .source_offset = 120 };

fn message(source: []const u8) Text {
    return .{ .bounds = .{ .x = 10, .y = 20, .width = 600, .height = 600 }, .viewport = .{ .x = 10, .y = 20, .width = 600, .height = 600 }, .text = source, .owner = owner };
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

test "Markdown links retain nested label styles and exact owned destination coordinates" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.enableCache();
    const source = "Read [**documentation** and `input`](https://example.test/source) now.";
    const destination = "https://example.test/source";
    const registry = try render(&fixture, message(source));
    try std.testing.expectEqual(@as(usize, 3), registry.len);
    const labels = [_][]const u8{ "documentation", "and", "input" };
    for (registry.targets[0..registry.len], labels) |target, label| {
        try std.testing.expectEqualStrings(label, target.label[0..target.label_len]);
        try std.testing.expect(!target.focusable and !target.activatable());
        try std.testing.expectEqual(@as(u8, 4), target.role);
        const control = target.action.message_link;
        try std.testing.expectEqualDeep(owner, control.owner);
        try std.testing.expectEqual(owner.source_offset + std.mem.indexOf(u8, source, destination).?, control.destination_offset);
        try std.testing.expectEqual(destination.len, control.destination_len);
        try std.testing.expectEqualStrings(label, source[control.fragment_offset - owner.source_offset ..][0..label.len]);
    }

    var canvas = fixture.canvas();
    const strong_width = try canvas.measure(.{ .text = "documentation", .face = .sans, .size = .body, .bold = true });
    try std.testing.expectApproxEqAbs(strong_width, registry.targets[0].bounds.width, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 45), registry.targets[2].bounds.width, 0.01);
    try std.testing.expect(registry.at(.{ registry.targets[1].bounds.x + registry.targets[1].bounds.width + 0.1, registry.targets[1].bounds.y + 12 }) == null);
    var underlines: usize = 0;
    const accent = @import("../render/cell_colors.zig").withPalette(canvas.theme.palette.accent, .white, &canvas.theme.terminal.palette);
    for (fixture.quads.items()) |quad| {
        if (quad.texture == 0 and quad.height == 1 and quad.r == accent.r and quad.g == accent.g and quad.b == accent.b and quad.a == accent.a) {
            underlines += 1;
        }
    }

    try std.testing.expectEqual(@as(usize, 3), underlines);
}

test "wrapped Markdown link fragments register only visible clipped text through resizing" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.enableCache();
    var text = message("Before [abcdefghijklmno abcdefghijklmno abcdefghijklmno](https://example.test/long) after.");
    text.bounds.width = 78;
    text.viewport = .{ .x = 15, .y = 37, .width = 55, .height = 50 };
    var canvas = fixture.canvas();
    const narrow_height = try text.measure(&canvas);
    const narrow = try render(&fixture, text);
    try std.testing.expect(narrow.len > 1);
    var previous: ?Target = null;
    for (narrow.targets[0..narrow.len]) |target| {
        try std.testing.expect(target.bounds.x >= text.viewport.x and target.bounds.y >= text.viewport.y);
        try std.testing.expect(target.bounds.x + target.bounds.width <= text.viewport.x + text.viewport.width + 0.01);
        try std.testing.expect(target.bounds.y + target.bounds.height <= text.viewport.y + text.viewport.height + 0.01);
        if (previous) |prior| {
            try std.testing.expect(!prior.id.eql(target.id));
            try std.testing.expectEqual(prior.action.message_link.destination_offset, target.action.message_link.destination_offset);
        }

        previous = target;
    }

    for (fixture.quads.items()) |quad| {
        try std.testing.expect(quad.x >= text.viewport.x and quad.y >= text.viewport.y);
        try std.testing.expect(quad.x + quad.width <= text.viewport.x + text.viewport.width + 0.01);
        try std.testing.expect(quad.y + quad.height <= text.viewport.y + text.viewport.height + 0.01);
    }

    text.bounds.width = 500;
    text.viewport = .{ .x = 10, .y = 20, .width = 500, .height = 600 };
    try std.testing.expect(try text.measure(&canvas) < narrow_height);
    const wide = try render(&fixture, text);
    try std.testing.expectEqual(@as(usize, 3), wide.len);
    for (wide.targets[0..wide.len]) |target| {
        try std.testing.expectApproxEqAbs(wide.targets[0].bounds.y, target.bounds.y, 0.01);
    }

    text.bounds.y = 1000;
    try std.testing.expectEqual(@as(usize, 0), (try render(&fixture, text)).len);
}

test "Markdown link measurement and literal output do not publish interactive regions" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.enableCache();
    var canvas = fixture.canvas();
    var text = message("[documentation](https://example.test)");
    _ = fixture.state.?.dispatcher.begin();
    _ = try text.measure(&canvas);
    try std.testing.expectEqual(@as(usize, 0), fixture.quads.items().len);
    try std.testing.expectEqual(@as(usize, 0), fixture.state.?.dispatcher.maps.preparing().len);
    fixture.state.?.dispatcher.seal();
    fixture.state.?.dispatcher.present(false);
    text.markdown = false;
    try std.testing.expectEqual(@as(usize, 0), (try render(&fixture, text)).len);
    text.markdown = true;
    text.code = true;
    try std.testing.expectEqual(@as(usize, 0), (try render(&fixture, text)).len);
    text.code = false;
    text.text = "```markdown\n[documentation](https://example.test)\n```";
    try std.testing.expectEqual(@as(usize, 0), (try render(&fixture, text)).len);
}

test "cached Markdown link plans rebuild stable visible controls without warm allocations" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.enableCache();
    var text = message("[" ++ "documentation " ** 160 ++ "](https://example.test/cached)");
    text.bounds.width = 220;
    text.viewport.height = 125;
    _ = try render(&fixture, text);
    const warm = try render(&fixture, text);
    try std.testing.expect(warm.len > 0 and warm.len < 64);
    var saved: [64]Target = undefined;
    const count = warm.len;
    @memcpy(saved[0..count], warm.targets[0..count]);
    const cache = fixture.state.?.message_layout orelse return error.MissingMessageLayoutCache;
    var has_plan = false;
    for (&cache.plans) |*plan| {
        has_plan = has_plan or plan.valid;
    }

    try std.testing.expect(has_plan);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    fixture.atlas.allocator = failing.allocator();
    fixture.quads.allocator = failing.allocator();
    defer fixture.atlas.allocator = std.testing.allocator;
    defer fixture.quads.allocator = std.testing.allocator;
    for (0..3) |_| {
        const replayed = try render(&fixture, text);
        try std.testing.expectEqual(count, replayed.len);
        for (replayed.targets[0..count], saved[0..count]) |current, expected| {
            try std.testing.expectEqualDeep(expected.id, current.id);
            try std.testing.expectEqualDeep(expected.bounds, current.bounds);
            try std.testing.expectEqualDeep(expected.action, current.action);
        }
    }

    try std.testing.expectEqual(@as(usize, 0), failing.allocated_bytes);
}

test "excess Markdown links preserve frame rendering and space for ordinary controls" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.enableCache();
    const text = message("[x](https://example.test) " ** 80);
    try std.testing.expectEqual(@as(usize, 64), (try render(&fixture, text)).len);
    fixture.quads.clear();
    const dispatcher = &fixture.state.?.dispatcher;
    _ = dispatcher.begin();
    for (0..Registry.capacity - 64) |index| {
        _ = try dispatcher.add(.{ .bounds = .{ .x = 1000, .y = 1000, .width = 1, .height = 1 }, .action = .{ .custom = @intCast(index) } });
    }

    var canvas = fixture.canvas();
    try text.draw(&canvas);
    try std.testing.expect(fixture.quads.items().len > 0);
    try std.testing.expectEqual(Registry.capacity - 64, dispatcher.maps.preparing().len);
    for (Registry.capacity - 64..Registry.capacity) |index| {
        _ = try dispatcher.add(.{ .bounds = .{ .x = 1000, .y = 1000, .width = 1, .height = 1 }, .action = .{ .custom = @intCast(index) } });
    }

    dispatcher.seal();
    dispatcher.present(true);
    try std.testing.expectEqual(Registry.capacity, dispatcher.maps.presented().len);
}

test "Markdown destination tooltip wraps inside a small window without adding hit targets" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.enableCache();
    var canvas = fixture.canvas();
    canvas.viewport = .{ 240, 120 };
    const destination = "https://example.test/" ++ "long-path-component/" ** 24;
    var text = message("[input](" ++ destination ++ ")");
    text.bounds = .{ .x = 185, .y = 80, .width = 50, .height = 40 };
    text.viewport = .{ .x = 0, .y = 0, .width = 240, .height = 120 };
    _ = fixture.state.?.dispatcher.begin();
    try text.draw(&canvas);
    const registry = fixture.state.?.dispatcher.maps.preparing();
    try std.testing.expectEqual(@as(usize, 1), registry.len);
    const target = registry.targets[0];
    const preview: @import("../widgets/MessageLinkPreview.zig") = .{ .control = target.action.message_link, .anchor = target.bounds, .pointer = .{ target.bounds.x + 1, target.bounds.y + 1 }, .destination = try .init(destination) };
    fixture.quads.clear();
    try preview.draw(&canvas);
    try std.testing.expect(fixture.quads.items().len > 2);
    try std.testing.expectEqual(@as(usize, 1), registry.len);
    for (fixture.quads.items()) |quad| {
        try std.testing.expect(quad.x >= 8 and quad.y >= 8);
        try std.testing.expect(quad.x + quad.width <= 232.01);
        try std.testing.expect(quad.y + quad.height <= 112.01);
    }

    canvas.viewport = .{ 32, 32 };
    fixture.quads.clear();
    try preview.draw(&canvas);
    try std.testing.expectEqual(@as(usize, 0), fixture.quads.items().len);
    try std.testing.expectEqual(@as(usize, 1), registry.len);
}

test "Markdown destination tooltip rejects changed content geometry and modal coverage" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.enableCache();
    var canvas = fixture.canvas();
    canvas.viewport = .{ 640, 480 };
    _ = fixture.state.?.dispatcher.begin();
    try message("[documentation](https://example.test)").draw(&canvas);
    const registry = fixture.state.?.dispatcher.maps.preparing();
    const target = registry.targets[0];
    const preview: @import("../widgets/MessageLinkPreview.zig") = .{ .control = target.action.message_link, .anchor = target.bounds, .pointer = .{ target.bounds.x + 1, target.bounds.y + 1 }, .destination = try .init("https://example.test") };
    fixture.quads.clear();
    var stale = preview;
    stale.control.owner.snapshot_revision += 1;
    try stale.draw(&canvas);
    try std.testing.expectEqual(@as(usize, 0), fixture.quads.items().len);
    stale = preview;
    stale.anchor.x += 1;
    try stale.draw(&canvas);
    try std.testing.expectEqual(@as(usize, 0), fixture.quads.items().len);
    stale = preview;
    stale.pointer = .{ 639, 479 };
    try stale.draw(&canvas);
    try std.testing.expectEqual(@as(usize, 0), fixture.quads.items().len);
    registry.modal_layer = 1;
    try preview.draw(&canvas);
    try std.testing.expectEqual(@as(usize, 0), fixture.quads.items().len);
    try std.testing.expectEqual(@as(usize, 1), registry.len);
    registry.modal_layer = 0;
    try preview.draw(&canvas);
    try std.testing.expect(fixture.quads.items().len > 0);
    try std.testing.expectEqual(@as(usize, 1), registry.len);
}
