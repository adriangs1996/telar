const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const Session = @import("Session.zig");
const Renderer = @import("../render/TerminalRenderer.zig");
const Canvas = @import("../widgets/Canvas.zig");
const QuadList = @import("../render/QuadList.zig");
const Quad = @import("../render/Quad.zig").Quad;
const solid_uv = @import("../render/Quad.zig").solid_uv;

test "Braille pattern replacement removes retained dots and blank Braille erases all ink" {
    const session = try Session.init();
    defer session.deinit();
    try session.bootstrap();
    try session.receiveFrame(1);
    const pane = session.gui.app.model.workspace.findPane(Session.pane_id).?;
    pane.cursor.visible = false;
    pane.buffer.cells[0] = cell(0xff);
    const shape_calls = session.renderer.atlas.?.shape_calls;
    const rasters = session.renderer.atlas.?.raster_attempts;
    const version = session.renderer.atlas.?.version;
    try paint(session);
    try std.testing.expectEqual(@as(usize, 8), session.renderer.quads.items().len);
    for (session.renderer.quads.items()) |dot| {
        try expectSolid(dot);
    }

    pane.buffer.cells[0] = cell(0x01);
    try paint(session);
    try std.testing.expectEqual(@as(usize, 1), session.renderer.repainted_cells);
    try std.testing.expectEqual(@as(usize, 1), session.renderer.quads.items().len);
    const top_left = session.renderer.quads.items()[0];
    pane.buffer.cells[0] = cell(0x80);
    try paint(session);
    try std.testing.expectEqual(@as(usize, 1), session.renderer.repainted_cells);
    try std.testing.expectEqual(@as(usize, 1), session.renderer.quads.items().len);
    const bottom_right = session.renderer.quads.items()[0];
    try std.testing.expect(bottom_right.x > top_left.x and bottom_right.y > top_left.y);
    const expected = [_]Quad{bottom_right};
    session.renderer.retained.invalidate();
    try paint(session);
    try std.testing.expectEqualSlices(Quad, &expected, session.renderer.quads.items());

    pane.buffer.cells[0] = cell(0);
    try paint(session);
    try std.testing.expectEqual(@as(usize, 1), session.renderer.repainted_cells);
    try std.testing.expectEqual(@as(usize, 0), session.renderer.quads.items().len);
    try paint(session);
    try std.testing.expectEqual(@as(usize, 0), session.renderer.repainted_cells);
    try std.testing.expectEqual(shape_calls, session.renderer.atlas.?.shape_calls);
    try std.testing.expectEqual(rasters, session.renderer.atlas.?.raster_attempts);
    try std.testing.expectEqual(version, session.renderer.atlas.?.version);
}

test "Braille uses terminal inverse faint decorations and retained block cursor ink" {
    const session = try Session.init();
    defer session.deinit();
    try session.bootstrap();
    try session.receiveFrame(1);
    const pane = session.gui.app.model.workspace.findPane(Session.pane_id).?;
    pane.buffer.cells[0] = cell(0x05);
    pane.buffer.cells[0].style = .{ .fg = .{ .rgb = .{ 255, 0, 0 } }, .bg = .{ .rgb = .{ 0, 0, 255 } }, .flags = .{ .inverse = true, .faint = true, .underline = .single, .strikethrough = true } };
    pane.cursor.x = 0;
    pane.cursor.y = 0;
    pane.cursor.appearance.shape = .block;
    session.renderer.theme.cursor_color = .{ 255, 255, 255 };
    session.renderer.theme.cursor_text_color = .{ 0, 255, 0 };
    try paint(session);
    const content = paneContent(session);
    const mesh = session.renderer.retained.at(.{ content.x, content.y });
    try std.testing.expectEqual(@as(usize, 5), mesh.len);
    try std.testing.expectEqual(@as(f32, 1), mesh.items()[0].r);
    try std.testing.expectEqual(@as(f32, 0), mesh.items()[0].b);
    for (mesh.items()[1..]) |ink| {
        try expectSolid(ink);
        try std.testing.expectEqual(@as(f32, 0), ink.r);
        try std.testing.expectEqual(@as(f32, 1), ink.b);
        try std.testing.expectEqual(@as(f32, 0.5), ink.a);
    }

    const frame = session.renderer.quads.items();
    const cursor = frame[frame.len - mesh.len ..];
    try std.testing.expectEqual(@as(f32, 1), cursor[0].r);
    for (cursor[1..], mesh.items()[1..]) |actual, original| {
        var recolored = original;
        recolored.r = 0;
        recolored.g = 1;
        recolored.b = 0;
        recolored.a = 1;
        try std.testing.expectEqualDeep(recolored, actual);
    }

    const retained = try std.testing.allocator.dupe(Quad, mesh.items());
    defer std.testing.allocator.free(retained);
    session.renderer.cursor_on = false;
    try paint(session);
    try std.testing.expectEqual(@as(usize, 0), session.renderer.repainted_cells);
    try std.testing.expectEqualSlices(Quad, retained, mesh.items());
    try std.testing.expectEqual(retained.len, session.renderer.quads.items().len);
    pane.buffer.cells[0].style.flags.invisible = true;
    try paint(session);
    try std.testing.expectEqual(@as(usize, 1), mesh.len);
    try std.testing.expectEqual(@as(usize, 1), session.renderer.quads.items().len);
}

test "Braille chrome preserves blank columns clipping colors and configured grid metrics" {
    var renderer = Renderer.init(std.testing.allocator);
    defer renderer.deinit();
    var quads = QuadList.init(std.testing.allocator);
    defer quads.deinit();
    for ([_]f32{ 1, 2 }) |scale| {
        renderer.config.font = .{ .size = 22, .line_height = 0.75, .letter_spacing = -5, .thicken = true };
        _ = try renderer.measure(.{ .width = 800, .height = 600, .scale = scale });
        var canvas: Canvas = .{ .atlas = &renderer.atlas.?, .quads = &quads, .metrics = renderer.metrics, .origin = .{ 8, 12 }, .theme = client.theme_support.default_theme };
        const area: core.Rect = .{ .x = 2, .y = 1, .w = 3, .h = 1 };
        const bounds = canvas.rect(area);
        const width: f32 = @floatFromInt(renderer.metrics.cell_width);
        const height: f32 = @floatFromInt(renderer.metrics.cell_height);
        const label = @import("../widgets/Label.zig"){ .text = "\u{2801}\u{2800}\u{2880}", .color = .{ .rgb = .{ 0, 255, 0 } }, .faint = true };
        const version = renderer.atlas.?.version;
        quads.clear();
        try canvas.text(area, label);
        try std.testing.expectEqual(@as(usize, 2), quads.items().len);
        const first = quads.items()[0];
        const last = quads.items()[1];
        try std.testing.expect(first.x >= bounds.x and first.x + first.width <= bounds.x + width);
        try std.testing.expect(last.x >= bounds.x + 2 * width and last.x + last.width <= bounds.x + 3 * width);
        try std.testing.expect(first.y + first.height / 2 < bounds.y + height / 2);
        try std.testing.expect(last.y + last.height / 2 > bounds.y + height / 2);
        for (quads.items()) |dot| {
            try expectSolid(dot);
            try std.testing.expect(dot.y >= bounds.y and dot.y + dot.height <= bounds.y + bounds.height);
            try std.testing.expectEqual(@as(f32, 0), dot.r);
            try std.testing.expectEqual(@as(f32, 1), dot.g);
            try std.testing.expectEqual(@as(f32, 0.5), dot.a);
        }

        quads.clear();
        var clipped = area;
        clipped.w = 2;
        try canvas.text(clipped, label);
        try std.testing.expectEqual(@as(usize, 1), quads.items().len);
        try std.testing.expectEqualDeep(first, quads.items()[0]);
        try std.testing.expectEqual(version, renderer.atlas.?.version);
    }
}

test "Braille animation stays within retained budgets without allocating or touching font caches" {
    const session = try Session.init();
    defer session.deinit();
    try session.bootstrap();
    try session.receiveFrame(1);
    const pane = session.gui.app.model.workspace.findPane(Session.pane_id).?;
    pane.cursor.visible = false;
    pane.buffer.cells[0] = cell(0);
    try paint(session);
    const renderer = &session.renderer;
    const calls = renderer.atlas.?.shape_calls;
    const rasters = renderer.atlas.?.raster_attempts;
    const version = renderer.atlas.?.version;
    const glyphs = renderer.atlas.?.glyphs.count();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    renderer.allocator = failing.allocator();
    renderer.quads.allocator = failing.allocator();
    renderer.cell_quads.allocator = failing.allocator();
    renderer.retained.allocator = failing.allocator();
    renderer.atlas.?.allocator = failing.allocator();
    defer {
        renderer.allocator = std.testing.allocator;
        renderer.quads.allocator = std.testing.allocator;
        renderer.cell_quads.allocator = std.testing.allocator;
        renderer.retained.allocator = std.testing.allocator;
        renderer.atlas.?.allocator = std.testing.allocator;
    }

    const patterns = [_]u8{ 0x01, 0x80, 0x55, 0xaa, 0xff, 0x00 };
    for (0..120) |index| {
        const pattern = patterns[index % patterns.len];
        pane.buffer.cells[0] = cell(pattern);
        try paint(session);
        try std.testing.expectEqual(@as(usize, 1), renderer.repainted_cells);
        try std.testing.expectEqual(@as(usize, @popCount(pattern)), renderer.quads.items().len);
    }

    try std.testing.expectEqual(calls, renderer.atlas.?.shape_calls);
    try std.testing.expectEqual(rasters, renderer.atlas.?.raster_attempts);
    try std.testing.expectEqual(version, renderer.atlas.?.version);
    try std.testing.expectEqual(glyphs, renderer.atlas.?.glyphs.count());
    try std.testing.expect(!failing.has_induced_failure);
}

fn cell(pattern: u8) core.Cell {
    var result: core.Cell = .{};
    result.len = std.unicode.utf8Encode(@as(u21, 0x2800) + pattern, &result.bytes) catch unreachable;
    return result;
}

fn paneContent(session: *Session) core.Rect {
    const model = session.gui.app.model.activeTabModel().?;
    return model.viewForPane(Session.pane_id, session.gui.region.area).?.content;
}

fn paint(session: *Session) !void {
    _ = try session.renderer.prepare(session.gui.projection());
    session.renderer.seal();
}

fn expectSolid(item: Quad) !void {
    try std.testing.expectEqual(solid_uv[0], item.u0);
    try std.testing.expectEqual(solid_uv[1], item.v0);
    try std.testing.expectEqual(solid_uv[0], item.u1);
    try std.testing.expectEqual(solid_uv[1], item.v1);
}
