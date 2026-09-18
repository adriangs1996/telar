const std = @import("std");
const Fixture = @import("ConversationFixture.zig");
const Store = @import("../diagrams/Store.zig");
const Image = @import("../diagrams/Image.zig");
const Text = @import("../widgets/MessageText.zig");
const Quad = @import("../render/Quad.zig").Quad;
const source = "```mermaid\nflowchart TD\nA[Start] --> B[Done]\n```";
const owner: @import("../widgets/MessageLayoutOwner.zig") = .{ .pane_id = @enumFromInt(1), .attachment_generation = 1, .pane_generation = 1, .snapshot_revision = 1, .item_identity = 7, .section = .body, .source_offset = 0 };

test "Mermaid measurement and hidden or incomplete fences never enqueue rendering" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    var canvas = fixture.canvas();
    canvas.diagrams = &store;
    var text: Text = .{ .bounds = .{ .x = 0, .y = 0, .width = 400, .height = 500 }, .viewport = .{ .x = 0, .y = 0, .width = 400, .height = 500 }, .text = source, .owner = owner };
    const fallback_height = try text.measure(&canvas);
    try std.testing.expect(store.nextJob() == null);
    text.text = source[0 .. source.len - 1];
    try text.draw(&canvas);
    try std.testing.expect(store.nextJob() == null);
    text.text = source;
    text.bounds.y = 1000;
    fixture.quads.clear();
    try text.draw(&canvas);
    try std.testing.expect(store.nextJob() == null);
    try std.testing.expectEqual(@as(usize, 0), fixture.quads.items().len);
    text.bounds.y = 0;
    try text.draw(&canvas);
    const job = store.nextJob() orelse return error.MissingDiagramRequest;
    try std.testing.expectEqualStrings("flowchart TD\nA[Start] --> B[Done]", job.text());
    try std.testing.expectEqual(fallback_height, try text.measure(&canvas));
    try text.draw(&canvas);
    try std.testing.expect(store.nextJob() == null);
    try std.testing.expect(firstDiagram(fixture.quads.items()) == null);
}

test "Mermaid ready images preserve complete aspect ratio and measured height through resize and clipping" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    var canvas = fixture.canvas();
    canvas.diagrams = &store;
    var text: Text = .{ .bounds = .{ .x = 10, .y = 10, .width = 640, .height = 2000 }, .viewport = .{ .x = 10, .y = 10, .width = 640, .height = 2000 }, .text = source, .owner = owner };
    try text.draw(&canvas);
    const job = store.nextJob() orelse return error.MissingDiagramRequest;
    try std.testing.expect(store.finish(.{ .id = job.id, .result = try makeImage(400, 800) }));
    store.beginFrame();
    fixture.quads.clear();
    const full_height = try text.measure(&canvas);
    try std.testing.expectApproxEqAbs(@as(f32, 852), full_height, 0.001);
    try text.draw(&canvas);
    const full = firstDiagram(fixture.quads.items()) orelse return error.MissingDiagramQuad;
    try std.testing.expectApproxEqAbs(@as(f32, 400), full.width, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 800), full.height, 0.001);
    try std.testing.expectEqual(@as(f32, 0), full.v0);
    try std.testing.expectEqual(@as(f32, 1), full.v1);
    try std.testing.expect(full.y + full.height <= text.bounds.y + full_height);
    text.bounds.width = 180;
    text.viewport.width = 180;
    fixture.quads.clear();
    const narrow_height = try text.measure(&canvas);
    try text.draw(&canvas);
    const narrow = firstDiagram(fixture.quads.items()).?;
    try std.testing.expectApproxEqAbs(@as(f32, 152), narrow.width, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 304), narrow.height, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 356), narrow_height, 0.001);
    try std.testing.expect(store.nextJob() == null);
    text.viewport.y = 100;
    text.viewport.height = 60;
    fixture.quads.clear();
    try text.draw(&canvas);
    const clipped = firstDiagram(fixture.quads.items()).?;
    try std.testing.expectApproxEqAbs(@as(f32, 60), clipped.height, 0.001);
    try std.testing.expect(clipped.v0 > 0 and clipped.v1 < 1);
    try std.testing.expectEqual(narrow_height, try text.measure(&canvas));
    for (fixture.quads.items()) |quad| {
        try std.testing.expect(quad.x >= text.viewport.x and quad.y >= text.viewport.y);
        try std.testing.expect(quad.x + quad.width <= text.viewport.x + text.viewport.width + 0.01);
        try std.testing.expect(quad.y + quad.height <= text.viewport.y + text.viewport.height + 0.01);
    }

    canvas.chrome.ratio = 2;
    text.bounds.width = 640;
    text.viewport = .{ .x = 10, .y = 10, .width = 640, .height = 2000 };
    fixture.quads.clear();
    try text.draw(&canvas);
    const scaled_job = store.nextJob() orelse return error.MissingDiagramRequest;
    try std.testing.expectEqual(@as(f32, 2), scaled_job.scale);
    var scaled_image = try makeImage(800, 1600);
    scaled_image.logical_width = 400;
    scaled_image.logical_height = 800;
    try std.testing.expect(store.finish(.{ .id = scaled_job.id, .result = scaled_image }));
    store.beginFrame();
    fixture.quads.clear();
    try std.testing.expectApproxEqAbs(@as(f32, 1272), try text.measure(&canvas), 0.001);
    try text.draw(&canvas);
    const scaled = firstDiagram(fixture.quads.items()).?;
    try std.testing.expectApproxEqAbs(@as(f32, 584), scaled.width, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1168), scaled.height, 0.001);
}

test "Mermaid failures preserve original code geometry and do not retry each frame" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    var canvas = fixture.canvas();
    canvas.diagrams = &store;
    var text: Text = .{ .bounds = .{ .x = 0, .y = 0, .width = 400, .height = 500 }, .viewport = .{ .x = 0, .y = 0, .width = 400, .height = 500 }, .text = source, .owner = owner };
    const code_height = try text.measure(&canvas);
    for ([_]anyerror{ error.InvalidDiagram, error.UnsupportedDiagram, error.DiagramLimit, error.RendererUnavailable, error.Timeout }) |failure| {
        text.owner.?.item_identity += 1;
        fixture.quads.clear();
        try text.draw(&canvas);
        const job = store.nextJob() orelse return error.MissingDiagramRequest;
        try std.testing.expectEqualStrings("flowchart TD\nA[Start] --> B[Done]", job.text());
        try std.testing.expect(store.finish(.{ .id = job.id, .result = failure }));
        store.beginFrame();
        fixture.quads.clear();
        try text.draw(&canvas);
        try std.testing.expectEqual(code_height, try text.measure(&canvas));
        try std.testing.expect(fixture.quads.items().len > 0);
        try std.testing.expect(firstDiagram(fixture.quads.items()) == null);
        try std.testing.expect(store.nextJob() == null);
        try text.draw(&canvas);
        try std.testing.expect(store.nextJob() == null);
    }
}

test "Mermaid closed content survives later snapshot revisions but equal-length edits request a new image" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    var canvas = fixture.canvas();
    canvas.diagrams = &store;
    var text: Text = .{ .bounds = .{ .x = 0, .y = 0, .width = 400, .height = 1000 }, .viewport = .{ .x = 0, .y = 0, .width = 400, .height = 1000 }, .text = source, .owner = owner };
    try text.draw(&canvas);
    const first = store.nextJob() orelse return error.MissingDiagramRequest;
    try std.testing.expect(store.finish(.{ .id = first.id, .result = try makeImage(100, 200) }));
    store.beginFrame();
    fixture.quads.clear();
    try text.draw(&canvas);
    const ready_height = try text.measure(&canvas);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    fixture.atlas.allocator = failing.allocator();
    fixture.quads.allocator = failing.allocator();
    defer fixture.atlas.allocator = std.testing.allocator;
    defer fixture.quads.allocator = std.testing.allocator;
    for (0..3) |_| {
        text.owner.?.snapshot_revision += 1;
        fixture.quads.clear();
        try std.testing.expectEqual(ready_height, try text.measure(&canvas));
        try text.draw(&canvas);
        try std.testing.expect(firstDiagram(fixture.quads.items()) != null);
        try std.testing.expect(store.nextJob() == null);
    }
    try std.testing.expectEqual(@as(usize, 0), failing.allocated_bytes);
    fixture.atlas.allocator = std.testing.allocator;
    fixture.quads.allocator = std.testing.allocator;
    text.text = "```mermaid\nflowchart TD\nA[Start] --> C[Done]\n```";
    try std.testing.expectEqual(source.len, text.text.len);
    fixture.quads.clear();
    try text.draw(&canvas);
    try std.testing.expect(firstDiagram(fixture.quads.items()) == null);
    const changed = store.nextJob() orelse return error.MissingDiagramRequest;
    try std.testing.expect(changed.id != first.id);
    try std.testing.expectEqualStrings("flowchart TD\nA[Start] --> C[Done]", changed.text());
}

test "measuring offscreen Mermaid images does not pin the full cache against visible requests" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    var canvas = fixture.canvas();
    canvas.diagrams = &store;
    var text: Text = .{ .bounds = .{ .x = 0, .y = 0, .width = 400, .height = 500 }, .viewport = .{ .x = 0, .y = 0, .width = 400, .height = 500 }, .text = source, .owner = owner };
    for (0..Store.capacity) |index| {
        text.owner.?.item_identity = index + 1;
        fixture.quads.clear();
        try text.draw(&canvas);
        const job = store.nextJob() orelse return error.MissingDiagramRequest;
        try std.testing.expect(store.finish(.{ .id = job.id, .result = try makeImage(16, 16) }));
        store.beginFrame();
    }

    text.bounds.y = -1000;
    for (0..Store.capacity) |index| {
        text.owner.?.item_identity = index + 1;
        try std.testing.expectApproxEqAbs(@as(f32, 68), try text.measure(&canvas), 0.001);
        fixture.quads.clear();
        try text.draw(&canvas);
        try std.testing.expectEqual(@as(usize, 0), fixture.quads.items().len);
    }

    text.bounds.y = 0;
    text.owner.?.item_identity = Store.capacity + 1;
    try text.draw(&canvas);
    try std.testing.expect(store.nextJob() != null);
}

fn makeImage(width: u32, height: u32) !Image {
    const pixels = try std.testing.allocator.alloc(u8, @as(usize, width) * height * 4);
    @memset(pixels, 255);
    return .{ .width = width, .height = height, .logical_width = @floatFromInt(width), .logical_height = @floatFromInt(height), .pixels = pixels };
}

fn firstDiagram(quads: []const Quad) ?Quad {
    for (quads) |quad| {
        if (quad.texture >= 2) {
            return quad;
        }
    }

    return null;
}
