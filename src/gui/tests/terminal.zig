const std = @import("std");
const Session = @import("Session.zig");

test "native terminal paints runtime cells and ACKs only successful captured frames" {
    const session = try Session.init();
    defer session.deinit();
    try session.bootstrap();
    try session.receiveFrame(1);
    const first = try session.gui.prepare(&session.renderer);
    try std.testing.expect(session.renderer.quads.items().len > 1);
    try std.testing.expectEqual(@as(usize, 0), session.ack_count);
    try std.testing.expectError(error.PresentationBusy, session.gui.prepare(&session.renderer));
    try session.gui.complete(first, false);
    try session.settle();
    try std.testing.expectEqual(@as(usize, 0), session.ack_count);
    const retry = try session.gui.prepare(&session.renderer);
    try session.receiveFrame(2);
    try session.gui.complete(first, true);
    try std.testing.expectEqual(retry, @intFromEnum(session.gui.lifecycle.active.?.token));
    try session.gui.complete(retry, true);
    try session.settle();
    try std.testing.expectEqual(@as(u64, 1), session.acknowledgements[0].frame_id);
    try std.testing.expectEqual(@as(u64, 2), session.gui.app.model.workspace.findPane(Session.pane_id).?.pending_frame_id);
    for (2..34) |frame| {
        try session.receiveFrame(frame);
        const token = try session.gui.prepare(&session.renderer);
        try session.gui.complete(token, true);
        try session.settle();
    }

    try std.testing.expectEqual(@as(usize, 33), session.ack_count);
    try std.testing.expectEqual(@as(usize, 0), session.input_len);
}

test "native keyboard and clipboard use the focused pane and bracketed paste modes" {
    const session = try Session.init();
    defer session.deinit();
    try session.bootstrap();
    try session.receiveFrame(1);
    const text = "printf 'hola\\n'";
    try session.gui.input.accept(.{ .kind = 1, .text = text.ptr, .len = text.len });
    try session.gui.input.accept(.{ .kind = 3, .code = 1 });
    const pasted = "café\nsecond line";
    try session.gui.input.accept(.{ .kind = 2, .text = pasted.ptr, .len = pasted.len });
    try session.gui.input.drain(&session.gui.app);
    try session.settle();
    try std.testing.expectEqualStrings("printf 'hola\\n'\r\x1b[200~café\nsecond line\x1b[201~", session.input[0..session.input_len]);
}

test "native resize publishes exact grid pixels and preserves runtime-owned pane identity" {
    const session = try Session.init();
    defer session.deinit();
    try session.bootstrap();
    const size = try session.renderer.metrics.measure(.{ .width = 303, .height = 199, .scale = 1 });
    try session.gui.resize(size);
    try session.settle();
    try std.testing.expectEqual(size.cols, session.gui.region.area.w);
    try std.testing.expectEqual(size.rows, session.gui.region.area.h);
    try std.testing.expectEqual(size.cell_width_px, session.gui.app.model.hostSize().cell_width_px);
    try std.testing.expect(session.resize_count > 0);
    try std.testing.expect(session.gui.app.model.workspace.findPane(Session.pane_id) != null);
}

test "native rendering visits every terminal leaf and clips to shared layout geometry" {
    const session = try Session.init();
    defer session.deinit();
    try session.bootstrap();
    try session.receiveFrame(1);
    try present(session);
    const model = session.gui.app.model.activeTabModel().?;
    const second: @import("telar-core").PaneId = @enumFromInt(11);
    try model.split(.{ .existing_pane = Session.pane_id, .new_pane = second, .location = Session.location, .axis = .horizontal, .area = session.gui.region.area });
    const token = try session.gui.prepare(&session.renderer);
    const commit = session.gui.lifecycle.active.?.delivery.commit;
    try std.testing.expectEqual(@as(u8, 2), commit.len);
    try std.testing.expectEqual(Session.pane_id, commit.panes[0].pane_id);
    try std.testing.expectEqual(second, commit.panes[1].pane_id);
    const width: f32 = @floatFromInt(@as(u32, session.gui.region.area.w) * session.renderer.metrics.cell_width);
    const height: f32 = @floatFromInt(@as(u32, session.gui.region.area.h) * session.renderer.metrics.cell_height);
    for (session.renderer.quads.items()) |quad| {
        try std.testing.expect(quad.x >= 0 and quad.y >= 0);
        try std.testing.expect(quad.x + quad.width <= width and quad.y + quad.height <= height);
    }

    try session.gui.complete(token, true);
    try session.settle();
    try expectFullRedraw(session);
}

test "native driver joins a blocked socket read before freeing the shared client" {
    const session = try Session.init();
    defer session.deinit();
    session.gui.app.transport_driver = @import("../host_ports.zig").transport(&session.gui.app);
    try @import("telar-client").runtime_io.scheduleRead(&session.gui.app);
    try std.testing.expect(session.driver.reader != null);
}

fn present(session: *Session) !void {
    const token = try session.gui.prepare(&session.renderer);
    try session.gui.complete(token, true);
    try session.settle();
}

fn expectFullRedraw(session: *Session) !void {
    const Quad = @import("../render/Quad.zig").Quad;
    const expected = try std.testing.allocator.dupe(Quad, session.renderer.quads.items());
    defer std.testing.allocator.free(expected);
    session.renderer.retained.invalidate();
    try present(session);
    try std.testing.expectEqualSlices(Quad, expected, session.renderer.quads.items());
}

test "retained cell damage rebuilds only changed cells and a cursor move reuses ink" {
    const session = try Session.init();
    defer session.deinit();
    try session.bootstrap();
    try session.receiveFrame(1);
    try present(session);
    const pane = session.gui.app.model.workspace.findPane(Session.pane_id).?;
    try std.testing.expectEqual(pane.buffer.cells.len, session.renderer.repainted_cells);
    const shape_calls = session.renderer.atlas.?.shape_calls;
    try present(session);
    try std.testing.expectEqual(@as(usize, 0), session.renderer.repainted_cells);
    try std.testing.expectEqual(shape_calls, session.renderer.atlas.?.shape_calls);
    pane.cursor.x = 2;
    try present(session);
    try std.testing.expectEqual(@as(usize, 0), session.renderer.repainted_cells);
    pane.buffer.cells[1].bytes[0] = '$';
    try present(session);
    try std.testing.expectEqual(@as(usize, 1), session.renderer.repainted_cells);
    try std.testing.expectEqual(shape_calls, session.renderer.atlas.?.shape_calls);
    try expectFullRedraw(session);

    // Damage in several unpresented updates must survive coalescing.
    pane.buffer.cells[0].style.flags.inverse = true;
    pane.buffer.cells[1].style.flags.bold = true;
    pane.buffer.cells[2].style.flags.underline = .single;
    const token = try session.gui.prepare(&session.renderer);
    try std.testing.expectEqual(@as(usize, 3), session.renderer.repainted_cells);
    try session.gui.complete(token, false);
    try present(session);
    try std.testing.expectEqual(@as(usize, 0), session.renderer.repainted_cells);
    try expectFullRedraw(session);
}

test "retained geometry matches full redraw through erasure wide cells styles and theme changes" {
    const session = try Session.init();
    defer session.deinit();
    try session.bootstrap();
    try session.receiveFrame(1);
    try present(session);
    const pane = session.gui.app.model.workspace.findPane(Session.pane_id).?;
    const texts = [_][]const u8{ "x", " ", "e\u{301}", "界" };
    for (0..32) |index| {
        const col = index % (pane.buffer.w - 1);
        const cell = &pane.buffer.cells[col];
        const text = texts[index % texts.len];
        @memcpy(cell.bytes[0..text.len], text);
        cell.len = @intCast(text.len);
        cell.width = if (index % 4 == 3) 2 else 1;
        cell.style.flags = .{ .inverse = index & 1 != 0, .italic = index & 2 != 0, .bold = index & 4 != 0, .underline = if (index & 8 != 0) .single else .none, .strikethrough = index & 16 != 0 };
        pane.buffer.cells[col + 1].width = if (cell.width == 2) 0 else 1;
        try present(session);
        try expectFullRedraw(session);
    }

    session.gui.theme.palette.text = .{ .rgb = .{ 12, 100, 200 } };
    session.gui.theme.palette.panel_bg = .{ .rgb = .{ 20, 40, 60 } };
    try present(session);
    try std.testing.expectEqual(pane.buffer.cells.len, session.renderer.repainted_cells);
    try expectFullRedraw(session);
    const size = try session.renderer.measure(.{ .width = 360, .height = 144, .scale = 2 });
    try session.gui.resize(size);
    try present(session);
    try std.testing.expect(session.renderer.repainted_cells > 0);
    try expectFullRedraw(session);
}

test "warm retained rendering and repeated glyph edits allocate no adapter storage" {
    const session = try Session.init();
    defer session.deinit();
    try session.bootstrap();
    try session.receiveFrame(1);
    try present(session);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    const renderer = &session.renderer;
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

    const pane = session.gui.app.model.workspace.findPane(Session.pane_id).?;
    for (0..8) |index| {
        pane.buffer.cells[1].bytes[0] = if (index % 2 == 0) '$' else ' ';
        try present(session);
        try std.testing.expectEqual(@as(usize, 1), renderer.repainted_cells);
    }

    try std.testing.expect(!failing.has_induced_failure);
}
