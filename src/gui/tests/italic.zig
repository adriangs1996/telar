const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const Session = @import("Session.zig");
const Renderer = @import("../render/TerminalRenderer.zig");
const QuadList = @import("../render/QuadList.zig");
const Quad = @import("../render/Quad.zig").Quad;
const Rect = @import("../render/Rect.zig");
const Atlas = @import("../text/GlyphAtlas.zig");

test "DejaVu italic New preserves rasterized overhang without font thickening" {
    try expectNaturalWord(false);
}

test "DejaVu italic New preserves rasterized overhang with font thickening" {
    try expectNaturalWord(true);
}

fn expectNaturalWord(thicken: bool) !void {
    const session = try configured(thicken, 1.4);
    defer session.deinit();
    const pane = session.gui.app.model.workspace.findPane(Session.pane_id).?;
    for ([_]bool{ false, true }) |bold| {
        word(session, .{ 2, 1 }, "New");
        for (pane.buffer.cells) |*cell| {
            cell.style.flags.bold = bold;
        }
        _ = try session.renderer.prepare(session.gui.projection());
        var natural = try naturalWord(session, .{ 2, 1 }, "New");
        defer natural.deinit();
        var visible_overhang = false;
        for (natural.items(), 0..) |glyph, index| {
            const area = content(session);
            const rect = session.renderer.metrics.rect(session.renderer.origin, .{ .x = area.x + 2 + @as(u16, @intCast(index)), .y = area.y + 1, .w = 1, .h = 1 });
            visible_overhang = visible_overhang or hasInkOutside(&session.renderer, glyph, rect);
        }
        try std.testing.expect(visible_overhang);
        try std.testing.expectEqualSlices(Quad, natural.items(), session.renderer.quads.items());
    }
}

test "italic overhang stays above adjacent backgrounds and the block cursor" {
    const session = try configured(true, 1.4);
    defer session.deinit();
    const pane = session.gui.app.model.workspace.findPane(Session.pane_id).?;
    word(session, .{ 2, 1 }, "New");
    pane.buffer.cells[pane.buffer.w + 3].style.bg = .{ .rgb = .{ 255, 0, 0 } };
    pane.cursor = .{ .visible = true, .x = 3, .y = 1, .appearance = .{ .shape = .block } };
    session.renderer.theme.cursor_color = .{ 0, 0, 255 };
    session.renderer.theme.cursor_text_color = .{ 0, 255, 0 };
    _ = try session.renderer.prepare(session.gui.projection());
    const frame = session.renderer.quads.items();
    try std.testing.expectEqual(@as(usize, 5), frame.len);
    try std.testing.expectEqual(@as(f32, 1), frame[0].r);
    try std.testing.expectEqual(@as(f32, 1), frame[1].b);
    var natural = try naturalWord(session, .{ 2, 1 }, "New");
    defer natural.deinit();
    // The N's slant crosses into the cursor cell and retains its anchor color.
    try std.testing.expectEqualDeep(natural.items()[0], frame[2]);
    var cursor_ink = natural.items()[1];
    cursor_ink.r = 0;
    cursor_ink.g = 1;
    cursor_ink.b = 0;
    try std.testing.expectEqualDeep(cursor_ink, frame[3]);
    try std.testing.expectEqualDeep(natural.items()[2], frame[4]);
}

test "italic clipping follows pane geometry while retained ink keeps its full texture" {
    const session = try configured(true, 0.75);
    defer session.deinit();
    const renderer = &session.renderer;
    const pane = session.gui.app.model.workspace.findPane(Session.pane_id).?;
    const area = content(session);
    const last: u16 = @min(area.w, pane.buffer.w) - 1;
    word(session, .{ last, 1 }, "N");
    _ = try renderer.prepare(session.gui.projection());
    var natural = try naturalWord(session, .{ last, 1 }, "N");
    defer natural.deinit();
    const mesh = renderer.retained.at(.{ area.x + last, area.y + 1 });
    try std.testing.expectEqualSlices(Quad, natural.items(), mesh.items()[1..]);
    const bounds = renderer.metrics.rect(renderer.origin, area);
    natural.clipFrom(0, bounds);
    try std.testing.expectEqualSlices(Quad, natural.items(), renderer.quads.items());
    try std.testing.expect(renderer.quads.items()[0].u1 < mesh.items()[1].u1);

    // Tall combining ink may cross a row boundary, but never the pane boundary.
    @memset(pane.buffer.cells, .{});
    const cluster = "A\u{301}\u{301}";
    const cell = &pane.buffer.cells[pane.buffer.w + 2];
    @memcpy(cell.bytes[0..cluster.len], cluster);
    cell.len = cluster.len;
    cell.style.flags.italic = true;
    _ = try renderer.prepare(session.gui.projection());
    const row = renderer.metrics.rect(renderer.origin, .{ .x = area.x + 2, .y = area.y + 1, .w = 1, .h = 1 });
    var above_row = false;
    for (renderer.quads.items()) |glyph| {
        above_row = above_row or glyph.y < row.y;
        try std.testing.expect(glyph.x >= bounds.x and glyph.y >= bounds.y);
        try std.testing.expect(glyph.x + glyph.width <= bounds.x + bounds.width);
        try std.testing.expect(glyph.y + glyph.height <= bounds.y + bounds.height);
    }
    try std.testing.expect(above_row);
}

test "italic selection and replacement reuse meshes without leaving stale overhang" {
    const session = try configured(true, 1.4);
    defer session.deinit();
    const renderer = &session.renderer;
    const pane = session.gui.app.model.workspace.findPane(Session.pane_id).?;
    word(session, .{ 2, 1 }, "New");
    var projection = session.gui.projection();
    _ = try renderer.prepare(projection);
    const expected = try std.testing.allocator.dupe(Quad, renderer.quads.items());
    defer std.testing.allocator.free(expected);
    const shape_calls = renderer.atlas.?.shape_calls;
    projection.copy = .{ .pane_id = pane.id, .view = .{ .cursor = .{ .x = 2, .y = 1 }, .anchor = .{ .x = 2, .y = 1 }, .linewise = false, .pointer = true } };
    _ = try renderer.prepare(projection);
    try std.testing.expectEqual(@as(usize, 1), renderer.repainted_cells);
    const selected = renderer.quads.items();
    try std.testing.expectEqual(expected.len + 1, selected.len);
    var selected_ink = expected[0];
    selected_ink.r = renderer.background.r;
    selected_ink.g = renderer.background.g;
    selected_ink.b = renderer.background.b;
    try std.testing.expectEqualDeep(selected_ink, selected[1]);
    try std.testing.expectEqualSlices(Quad, expected[1..], selected[2..]);
    try std.testing.expect(!pane.buffer.cells[pane.buffer.w + 2].style.flags.inverse);
    projection.copy = null;
    _ = try renderer.prepare(projection);
    try std.testing.expectEqualSlices(Quad, expected, renderer.quads.items());
    try std.testing.expectEqual(@as(usize, 1), renderer.repainted_cells);

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    renderer.quads.allocator = failing.allocator();
    renderer.cell_quads.allocator = failing.allocator();
    renderer.retained.allocator = failing.allocator();
    renderer.atlas.?.allocator = failing.allocator();
    defer {
        renderer.quads.allocator = std.testing.allocator;
        renderer.cell_quads.allocator = std.testing.allocator;
        renderer.retained.allocator = std.testing.allocator;
        renderer.atlas.?.allocator = std.testing.allocator;
    }
    for (0..20) |index| {
        pane.buffer.cells[pane.buffer.w + 2].bytes[0] = if (index % 2 == 0) ' ' else 'N';
        _ = try renderer.prepare(projection);
        try std.testing.expectEqual(@as(usize, 1), renderer.repainted_cells);
        const retained = try std.testing.allocator.dupe(Quad, renderer.quads.items());
        defer std.testing.allocator.free(retained);
        renderer.retained.invalidate();
        _ = try renderer.prepare(projection);
        try std.testing.expectEqualSlices(Quad, retained, renderer.quads.items());
    }
    try std.testing.expectEqual(shape_calls, renderer.atlas.?.shape_calls);
    try std.testing.expect(!failing.has_induced_failure);
}

fn configured(thicken: bool, line_height: f32) !*Session {
    const session = try Session.init();
    errdefer session.deinit();
    var config: client.GuiConfig = .{ .font = .{ .size = 22, .line_height = line_height, .thicken = thicken, .thicken_strength = 255 } };
    try config.font.family.set("DejaVu Sans Mono");
    const renderer = Renderer.configured(std.testing.allocator, std.testing.io, .{ .config = config, .viewport = .{ .width = 390, .height = 276, .scale = 1 } }) catch |err| switch (err) {
        error.FontFamilyNotFound => return error.SkipZigTest,
        else => return err,
    };
    session.renderer.deinit();
    session.renderer = renderer;
    const size = try session.renderer.measure(.{ .width = 390, .height = 276, .scale = 1 });
    try session.gui.resize(size, renderer.theme);
    try session.bootstrap();
    try session.receiveFrame(1);
    const pane = session.gui.app.model.workspace.findPane(Session.pane_id).?;
    @memset(pane.buffer.cells, .{});
    pane.cursor.visible = false;
    return session;
}

fn content(session: *Session) core.Rect {
    return session.gui.app.model.activeTabModel().?.viewForPane(Session.pane_id, session.gui.region.area).?.content;
}

fn word(session: *Session, point: [2]u16, text: []const u8) void {
    const pane = session.gui.app.model.workspace.findPane(Session.pane_id).?;
    for (text, 0..) |byte, index| {
        const cell = &pane.buffer.cells[@as(usize, point[1]) * pane.buffer.w + point[0] + index];
        cell.* = .{};
        cell.bytes[0] = byte;
        cell.style.flags.italic = true;
    }
}

fn naturalWord(session: *Session, point: [2]u16, text: []const u8) !QuadList {
    var list = QuadList.init(std.testing.allocator);
    errdefer list.deinit();
    const renderer = &session.renderer;
    const pane = session.gui.app.model.workspace.findPane(Session.pane_id).?;
    const area = content(session);
    for (0..text.len) |index| {
        const cell = pane.buffer.cells[@as(usize, point[1]) * pane.buffer.w + point[0] + index];
        const rect = renderer.metrics.rect(renderer.origin, .{ .x = area.x + point[0] + @as(u16, @intCast(index)), .y = area.y + point[1], .w = 1, .h = 1 });
        _ = try renderer.atlas.?.place(.{ .text = cell.text(), .x = rect.x, .y = rect.y + renderer.metrics.baseline, .color = renderer.foreground, .pixel_height = renderer.metrics.pixel_height, .cell_bounds = renderer.metrics.glyphCell(), .bold = cell.style.flags.bold, .italic = true }, &list);
    }
    return list;
}

fn hasInkOutside(renderer: *Renderer, glyph: Quad, rect: Rect) bool {
    const left: usize = @intFromFloat(@round(glyph.u0 * Atlas.side));
    const top: usize = @intFromFloat(@round(glyph.v0 * Atlas.side));
    const width: usize = @intFromFloat(@round((glyph.u1 - glyph.u0) * Atlas.side));
    const height: usize = @intFromFloat(@round((glyph.v1 - glyph.v0) * Atlas.side));
    for (0..height) |row| {
        for (0..width) |col| {
            const x = glyph.x + @as(f32, @floatFromInt(col)) + 0.5;
            const y = glyph.y + @as(f32, @floatFromInt(row)) + 0.5;
            if ((x < rect.x or x >= rect.x + rect.width or y < rect.y or y >= rect.y + rect.height) and renderer.atlas.?.pixels[(top + row) * Atlas.side + left + col] != 0) {
                return true;
            }
        }
    }
    return false;
}
