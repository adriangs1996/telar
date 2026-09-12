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
}

test "native driver joins a blocked socket read before freeing the shared client" {
    const session = try Session.init();
    defer session.deinit();
    session.gui.app.transport_driver = @import("../host_ports.zig").transport(&session.gui.app);
    try @import("telar-client").runtime_io.scheduleRead(&session.gui.app);
    try std.testing.expect(session.driver.reader != null);
}
