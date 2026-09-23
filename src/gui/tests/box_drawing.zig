const data = @import("model");
const Quad_module = @import("../render/Quad.zig");
const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const Session = @import("Session.zig");
const Renderer = @import("../render/TerminalRenderer.zig");
const Canvas = @import("../widgets/Canvas.zig");
const CellMesh = @import("../render/CellMesh.zig");
const QuadList = @import("../render/QuadList.zig");
const Quad = @import("../render/Quad.zig").Quad;

test "terminal box borders join adjacent cells for light heavy double and mixed strokes" {
    const session = try Session.init();
    defer session.deinit();
    try session.bootstrap();
    try session.receiveFrame(1);
    const pane = session.gui.app.model.workspace.findPane(Session.pane_id).?;
    pane.cursor.visible = false;
    const frames = [_][5][]const u8{
        .{ "┌─┬─┐", "│ │ │", "├─┼─┤", "│ │ │", "└─┴─┘" },
        .{ "┏━┳━┓", "┃ ┃ ┃", "┣━╋━┫", "┃ ┃ ┃", "┗━┻━┛" },
        .{ "╔═╦═╗", "║ ║ ║", "╠═╬═╣", "║ ║ ║", "╚═╩═╝" },
        .{ "╒═╤═╕", "│ │ │", "├─┼─┤", "│ │ │", "╘═╧═╛" },
    };
    const shapes = session.gui.renderer.atlas.?.shape_calls;
    const rasters = session.gui.renderer.atlas.?.raster_attempts;
    const version = session.gui.renderer.atlas.?.version;
    for (frames) |frame| {
        @memset(pane.buffer.cells, .{});
        for (frame, 0..) |row, y| {
            var iter: core.GraphemeIterator = .{ .bytes = row };
            var x: usize = 0;
            while (iter.next()) |cluster| : (x += 1) {
                pane.buffer.cells[y * pane.buffer.w + x] = fromText(cluster.bytes);
            }
        }

        try paint(session);
        var first: [CellMesh.capacity]Quad = undefined;
        var second: [CellMesh.capacity]Quad = undefined;
        for ([_]u16{ 0, 2, 4 }) |row| {
            for (0..4) |col| {
                try expectJoin(mesh(session, @intCast(col), row).collect(&first)[1..], mesh(session, @intCast(col + 1), row).collect(&second)[1..], false);
            }
        }

        for ([_]u16{ 0, 2, 4 }) |col| {
            for (0..4) |row| {
                try expectJoin(mesh(session, col, @intCast(row)).collect(&first)[1..], mesh(session, col, @intCast(row + 1)).collect(&second)[1..], true);
            }
        }

        for (session.gui.renderer.quads.items()) |item| {
            try std.testing.expect(isSolid(item));
        }
    }

    try std.testing.expectEqual(shapes, session.gui.renderer.atlas.?.shape_calls);
    try std.testing.expectEqual(rasters, session.gui.renderer.atlas.?.raster_attempts);
    try std.testing.expectEqual(version, session.gui.renderer.atlas.?.version);
}

test "faint straight box glyphs never blend overlapping strokes or consult a font" {
    const session = try Session.init();
    defer session.deinit();
    try session.bootstrap();
    try session.receiveFrame(1);
    const pane = session.gui.app.model.workspace.findPane(Session.pane_id).?;
    pane.cursor.visible = false;
    const shapes = session.gui.renderer.atlas.?.shape_calls;
    const rasters = session.gui.renderer.atlas.?.raster_attempts;
    for (0x2500..0x2580) |value| {
        if (value >= 0x256d and value <= 0x2573) {
            continue;
        }

        pane.buffer.cells[0] = cell(@intCast(value));
        pane.buffer.cells[0].style.flags = .{ .faint = true, .bold = true, .italic = true };
        try paint(session);
        var storage: [CellMesh.capacity]Quad = undefined;
        const ink = mesh(session, 0, 0).collect(&storage)[1..];
        try std.testing.expect(ink.len > 0 and ink.len < CellMesh.capacity);
        for (ink, 0..) |a, index| {
            try std.testing.expect(isSolid(a));
            try std.testing.expectEqual(@as(f32, 0.5), a.a);
            for (ink[index + 1 ..]) |b| {
                const width = @min(a.x + a.width, b.x + b.width) - @max(a.x, b.x);
                const height = @min(a.y + a.height, b.y + b.height) - @max(a.y, b.y);
                try std.testing.expect(width <= 0.001 or height <= 0.001);
            }
        }
    }

    try std.testing.expectEqual(shapes, session.gui.renderer.atlas.?.shape_calls);
    try std.testing.expectEqual(rasters, session.gui.renderer.atlas.?.raster_attempts);
}

test "box replacement and erasure match full rebuilding with cached rounded corners" {
    const session = try Session.init();
    defer session.deinit();
    try session.bootstrap();
    try session.receiveFrame(1);
    const pane = session.gui.app.model.workspace.findPane(Session.pane_id).?;
    pane.cursor.visible = false;
    pane.buffer.cells[0] = cell(0x253c);
    try paint(session);
    const shapes = session.gui.renderer.atlas.?.shape_calls;
    const rasters = session.gui.renderer.atlas.?.raster_attempts;
    for ([_]u21{ 0x256d, 0x256e, 0x256f, 0x2570, ' ', 0x2500 }) |cp| {
        pane.buffer.cells[0] = cell(cp);
        try paint(session);
        try std.testing.expectEqual(@as(usize, 1), session.gui.renderer.repainted_cells);
        const frame = session.gui.renderer.quads.items();
        if (cp == ' ') {
            try std.testing.expectEqual(@as(usize, 0), frame.len);
        } else if (cp >= 0x256d and cp <= 0x2570) {
            try std.testing.expectEqual(@as(usize, 1), frame.len);
            try std.testing.expect(!isSolid(frame[0]));
        }

        var expected: [CellMesh.capacity]Quad = undefined;
        @memcpy(expected[0..frame.len], frame);
        const count = frame.len;
        session.gui.renderer.retained.invalidate();
        try paint(session);
        try std.testing.expectEqualSlices(
            Quad,
            expected[0..count],
            session.gui.renderer.quads.items(),
        );
        try paint(session);
        try std.testing.expectEqual(@as(usize, 0), session.gui.renderer.repainted_cells);
    }

    try std.testing.expectEqual(shapes, session.gui.renderer.atlas.?.shape_calls);
    try std.testing.expectEqual(rasters, session.gui.renderer.atlas.?.raster_attempts);
}

test "chrome box strokes follow line height letter spacing and scale through the shared atlas" {
    for ([_]f32{ 0.75, 1.4 }) |line_height| {
        for ([_]f32{ 1, 2 }) |scale| {
            var renderer = Renderer.init(std.testing.allocator);
            defer renderer.deinit();
            renderer.config.font = .{ .size = 22, .line_height = line_height, .letter_spacing = 3 };
            _ = try renderer.measure(.{ .width = 800, .height = 600, .scale = scale });
            var quads = QuadList.init(std.testing.allocator);
            defer quads.deinit();
            var canvas: Canvas = .{ .atlas = &renderer.atlas.?, .quads = &quads, .metrics = renderer.metrics, .origin = .{ 7, 11 }, .theme = data.theme_support.default_theme };
            const area: core.Rect = .{ .x = 1, .y = 2, .w = 3, .h = 1 };
            const bounds = canvas.rect(area);
            try canvas.text(area, .{ .text = "│ │", .faint = true });
            try std.testing.expectEqual(@as(usize, 2), quads.items().len);
            for (quads.items()) |stroke| {
                try std.testing.expect(isSolid(stroke));
                try std.testing.expectEqual(bounds.y, stroke.y);
                try std.testing.expectEqual(bounds.height, stroke.height);
                try std.testing.expectEqual(@as(f32, 0.5), stroke.a);
            }

            quads.clear();
            try canvas.text(area, .{ .text = "────" });
            var left: f32 = std.math.inf(f32);
            var right: f32 = -std.math.inf(f32);
            for (quads.items()) |stroke| {
                try std.testing.expect(isSolid(stroke));
                left = @min(left, stroke.x);
                right = @max(right, stroke.x + stroke.width);
                try std.testing.expect(stroke.y >= bounds.y and stroke.y + stroke.height <= bounds.y + bounds.height);
            }

            try std.testing.expectEqual(bounds.x, left);
            try std.testing.expectEqual(bounds.x + bounds.width, right);
        }
    }
}

test "all box glyphs animate within retained capacity without allocation after warming" {
    const session = try Session.init();
    defer session.deinit();
    try session.bootstrap();
    try session.receiveFrame(1);
    const pane = session.gui.app.model.workspace.findPane(Session.pane_id).?;
    pane.cursor.visible = false;
    for (0x2500..0x2580) |cp| {
        pane.buffer.cells[0] = cell(@intCast(cp));
        pane.buffer.cells[0].style.flags = .{ .underline = .single, .strikethrough = true, .bold = true, .italic = true };
        try paint(session);
    }

    const renderer = &session.gui.renderer;
    const shapes = renderer.atlas.?.shape_calls;
    const rasters = renderer.atlas.?.raster_attempts;
    const version = renderer.atlas.?.version;
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

    for (0..256) |index| {
        pane.buffer.cells[0] = cell(@intCast(0x2500 + index % 128));
        pane.buffer.cells[0].style.flags = .{ .underline = .single, .strikethrough = true, .bold = true, .italic = true };
        try paint(session);
        try std.testing.expectEqual(@as(usize, 1), renderer.repainted_cells);
        try std.testing.expect(renderer.quads.items().len < CellMesh.capacity);
    }

    try std.testing.expectEqual(shapes, renderer.atlas.?.shape_calls);
    try std.testing.expectEqual(rasters, renderer.atlas.?.raster_attempts);
    try std.testing.expectEqual(version, renderer.atlas.?.version);
    try std.testing.expect(!failing.has_induced_failure);
}

fn fromText(text: []const u8) core.Cell {
    var result: core.Cell = .{};
    @memcpy(result.bytes[0..text.len], text);
    result.len = @intCast(text.len);
    return result;
}

fn cell(cp: u21) core.Cell {
    var result: core.Cell = .{};
    result.len = std.unicode.utf8Encode(cp, &result.bytes) catch unreachable;
    return result;
}

fn paint(session: *Session) !void {
    _ = try session.gui.renderer.prepare(session.gui.projection());
    session.gui.renderer.seal();
}

fn mesh(session: *Session, x: u16, y: u16) CellMesh {
    const model = session.gui.app.model.activeTabModel().?;
    const area = model.viewForPane(Session.pane_id, session.gui.region.area).?.content;
    return session.gui.renderer.retained.at(
        .{
            area.x + x,
            area.y + y,
        },
    );
}

fn expectJoin(first: []const Quad, second: []const Quad, vertical: bool) !void {
    var joined = false;
    for (first) |a| {
        for (second) |b| {
            const seam = if (vertical) @abs(a.y + a.height - b.y) else @abs(a.x + a.width - b.x);
            const overlap = if (vertical)
                @min(a.x + a.width, b.x + b.width) - @max(a.x, b.x)
            else
                @min(a.y + a.height, b.y + b.height) - @max(a.y, b.y);
            joined = joined or (seam < 0.001 and overlap > 0);
        }
    }

    try std.testing.expect(joined);
}

fn isSolid(item: Quad) bool {
    return item.u0 == Quad_module.solid_uv[0] and item.v0 == Quad_module.solid_uv[1] and item.u1 == Quad_module.solid_uv[0] and item.v1 == Quad_module.solid_uv[1];
}
