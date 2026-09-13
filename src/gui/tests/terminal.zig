const std = @import("std");
const Session = @import("Session.zig");

test "GUI font metrics apply size spacing and display scale once" {
    const Renderer = @import("../render/TerminalRenderer.zig");
    var renderer = Renderer.init(std.testing.allocator);
    defer renderer.deinit();
    renderer.config.font = .{ .size = 20, .line_height = 1.5, .letter_spacing = 2 };
    for ([_]f32{ 1, 2 }) |scale| {
        const size = try renderer.measure(.{ .width = 800, .height = 600, .scale = scale });
        const atlas = &renderer.atlas.?;
        try std.testing.expectEqual(@as(u16, @intFromFloat(20 * scale)), atlas.pixel_height);
        try std.testing.expectEqual(atlas.cellWidth() + @as(u16, @intFromFloat(2 * scale)), size.cell_width_px);
        try std.testing.expectEqual(@as(u16, @intFromFloat(@round(@as(f32, @floatFromInt(atlas.lineHeight())) * 1.5))), size.cell_height_px);
        try std.testing.expectEqual(800 / size.cell_width_px, size.cols);
        try std.testing.expectEqual(600 / size.cell_height_px, size.rows);
    }
}

test "native font lookup resolves installed faces and fails explicitly for missing families" {
    const client = @import("telar-client");
    const Source = @import("../text/FontSource.zig");
    const Atlas = @import("../text/GlyphAtlas.zig");
    var family: client.FontFamily = .{};
    try family.set("Telar-Test-Missing-Family-98a34b1");
    try std.testing.expectError(error.FontFamilyNotFound, Source.load(std.testing.allocator, std.testing.io, &family));
    try family.set(if (@import("builtin").os.tag == .macos) "Menlo" else "DejaVu Sans Mono");
    var source = try Source.load(std.testing.allocator, std.testing.io, &family);
    defer source.deinit(std.testing.allocator);
    try std.testing.expect(source.owned);
    var atlas = try Atlas.init(std.testing.allocator, .{ .font = source.bytes, .pixel_height = 18, .face_index = source.match.face_index, .postscript = std.mem.sliceTo(&source.match.postscript, 0) });
    defer atlas.deinit();
    try atlas.prepareFallbacks();
    try std.testing.expect(atlas.cellWidth() > 0);
}

test "cursor shapes focus and blink reuse retained ink without changing the atlas" {
    const core = @import("telar-core");
    const session = try Session.init();
    defer session.deinit();
    try session.bootstrap();
    try session.receiveFrame(1);
    const pane = session.gui.app.model.workspace.findPane(Session.pane_id).?;
    pane.cursor.x = 0;
    try present(session);
    const ink = try std.testing.allocator.dupe(@import("../render/Quad.zig").Quad, session.renderer.retained.at(.{ 0, 0 }).items());
    defer std.testing.allocator.free(ink);
    const shape_calls = session.renderer.atlas.?.shape_calls;
    const version = session.renderer.atlas_version;
    const cell_width: f32 = @floatFromInt(session.renderer.metrics.cell_width);
    const cell_height: f32 = @floatFromInt(session.renderer.metrics.cell_height);
    for (std.meta.tags(core.Cursor.Shape)) |shape| {
        pane.cursor.appearance.shape = shape;
        try present(session);
        const quads = session.renderer.quads.items();
        const count: usize = if (shape == .hollow) 4 else if (shape == .block or shape == .default) ink.len else 1;
        const first = quads[quads.len - count];
        try std.testing.expectEqual(if (shape == .bar) @as(f32, 2) else cell_width, first.width);
        try std.testing.expectEqual(if (shape == .underline or shape == .hollow) @as(f32, 2) else cell_height, first.height);
        try std.testing.expectEqual(if (shape == .underline) cell_height - 2 else @as(f32, 0), first.y);
        try std.testing.expectEqual(@as(usize, 0), session.renderer.repainted_cells);
        session.renderer.cursor_on = false;
        try present(session);
        try std.testing.expectEqual(quads.len - count, session.renderer.quads.items().len);
        session.renderer.cursor_on = true;
    }

    try std.testing.expectEqualSlices(@import("../render/Quad.zig").Quad, ink, session.renderer.retained.at(.{ 0, 0 }).items());
    try std.testing.expectEqual(shape_calls, session.renderer.atlas.?.shape_calls);
    try std.testing.expectEqual(version, session.renderer.atlas_version);
    pane.cursor.appearance.shape = .bar;
    session.renderer.focused = false;
    try present(session);
    const hollow = session.renderer.quads.items();
    try std.testing.expectEqual(cell_width, hollow[hollow.len - 4].width);
    try std.testing.expectEqual(@as(f32, 2), hollow[hollow.len - 4].height);
    session.renderer.focused = true;
    session.renderer.config.cursor.style = .underline;
    pane.cursor.appearance.shape = .default;
    try present(session);
    const underline = session.renderer.quads.items();
    try std.testing.expectEqual(cell_height - 2, underline[underline.len - 1].y);
}

test "a block cursor recolors wide cell ink and ANSI colors belong to the GUI theme" {
    const session = try Session.init();
    defer session.deinit();
    try session.bootstrap();
    try session.receiveFrame(1);
    const pane = session.gui.app.model.workspace.findPane(Session.pane_id).?;
    pane.buffer.cells[0] = .{ .bytes = .{ 0xe7, 0x95, 0x8c } ++ .{0} ** 13, .len = 3, .width = 2, .style = .{ .fg = .{ .indexed = 1 } } };
    pane.buffer.cells[1].width = 0;
    pane.cursor.x = 1;
    session.renderer.theme.palette[1] = .{ 12, 34, 56 };
    session.renderer.theme.cursor_color = .{ 255, 0, 0 };
    session.renderer.theme.cursor_text_color = .{ 0, 255, 0 };
    try present(session);
    const mesh = session.renderer.retained.at(.{ 0, 0 });
    const quads = session.renderer.quads.items();
    const cursor = quads[quads.len - mesh.len];
    try std.testing.expectEqual(@as(f32, 0), cursor.x);
    try std.testing.expectEqual(@as(f32, @floatFromInt(session.renderer.metrics.cell_width * 2)), cursor.width);
    try std.testing.expectEqual(@as(f32, 1), cursor.r);
    for (quads[quads.len - mesh.len + 1 ..]) |glyph| {
        try std.testing.expectEqual(@as(f32, 0), glyph.r);
        try std.testing.expectEqual(@as(f32, 1), glyph.g);
    }
    try std.testing.expectApproxEqAbs(@as(f32, 12.0 / 255.0), mesh.items()[1].r, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 34.0 / 255.0), mesh.items()[1].g, 0.001);
}

test "native terminal acknowledges received patches while presentation is busy or fails" {
    const session = try Session.init();
    defer session.deinit();
    try session.bootstrap();
    try session.receiveFrame(1);
    try session.settle();
    const first = try session.gui.prepare(&session.renderer);
    try std.testing.expect(session.renderer.quads.items().len > 1);
    try std.testing.expectEqual(@as(usize, 1), session.ack_count);
    try std.testing.expectError(error.PresentationBusy, session.gui.prepare(&session.renderer));
    try session.gui.complete(first, false);
    try session.settle();
    try std.testing.expectEqual(@as(usize, 1), session.ack_count);
    const retry = try session.gui.prepare(&session.renderer);
    const Quad = @import("../render/Quad.zig").Quad;
    const frozen = try std.testing.allocator.dupe(Quad, session.renderer.quads.items());
    defer std.testing.allocator.free(frozen);
    for (2..34) |frame| {
        try session.receiveFrame(frame);
        try session.settle();
        try std.testing.expectEqual(frame, session.ack_count);
        try std.testing.expectEqual(frame, session.acknowledgements[frame - 1].frame_id);
    }

    try std.testing.expectEqualSlices(Quad, frozen, session.renderer.quads.items());
    try std.testing.expectEqualStrings("H", session.gui.app.model.workspace.findPane(Session.pane_id).?.buffer.cells[0].text());
    try session.gui.complete(first, true);
    try std.testing.expectEqual(retry, @intFromEnum(session.gui.lifecycle.active.?.token));
    try session.gui.complete(retry, true);
    try session.settle();
    try std.testing.expectEqual(@as(u64, 1), session.acknowledgements[0].frame_id);
    try std.testing.expectEqual(@as(u64, 33), session.gui.app.model.workspace.findPane(Session.pane_id).?.pending_frame_id);
    try present(session);
    try std.testing.expectEqual(@as(u64, 0), session.gui.app.model.workspace.findPane(Session.pane_id).?.pending_frame_id);
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
    try session.gui.resize(size, session.renderer.theme);
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
    try std.testing.expect(session.gui.app.runtime_transport.receive_pending);
}

test "native inbox holds input and GPU completion until the consumer runs" {
    const session = try Session.init();
    defer session.deinit();
    try session.bootstrap();
    try session.receiveFrame(1);
    try session.settle();
    const token = try session.gui.prepare(&session.renderer);
    const inbox = &session.driver.inbox;
    var text = [_]u8{'x'} ** 80;
    try session.gui.input.accept(.{ .kind = 1, .text = &text, .len = text.len });
    @memset(&text, 'z');
    try inbox.notify(.input_ready);
    try inbox.post(.{ .presented = .{ .token = token, .delivered = true } });
    try std.testing.expectEqual(@as(usize, 0), session.input_len);
    try std.testing.expect(session.gui.lifecycle.active != null);
    _ = try session.gui.pump();
    try std.testing.expect(session.gui.input.len >= 48);
    try session.settle();
    try std.testing.expectEqual(@as(usize, 80), session.input_len);
    for (session.input[0..session.input_len]) |byte| {
        try std.testing.expectEqual(@as(u8, 'x'), byte);
    }

    try std.testing.expect(session.gui.lifecycle.active == null);
    try std.testing.expectEqual(@as(usize, 1), session.ack_count);
    const consumed = inbox.snapshot().consumed;
    _ = try session.gui.pump();
    try std.testing.expectEqual(consumed, inbox.snapshot().consumed);
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

    session.renderer.theme.foreground = .{ 12, 100, 200 };
    session.renderer.theme.background = .{ 20, 40, 60 };
    try present(session);
    try std.testing.expectEqual(pane.buffer.cells.len, session.renderer.repainted_cells);
    try expectFullRedraw(session);
    const size = try session.renderer.measure(.{ .width = 360, .height = 144, .scale = 2 });
    try session.gui.resize(size, session.renderer.theme);
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

    const shape_calls = renderer.atlas.?.shape_calls;
    for (0..20) |phase| {
        renderer.cursor_on = phase % 2 == 0;
        try present(session);
        try std.testing.expectEqual(@as(usize, 0), renderer.repainted_cells);
    }
    try std.testing.expectEqual(shape_calls, renderer.atlas.?.shape_calls);
    try std.testing.expect(!failing.has_induced_failure);
}
