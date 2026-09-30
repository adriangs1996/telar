const std = @import("std");
const native = @import("../native/native.zig");
const window_callbacks = @import("../native/window_callbacks.zig");
const TestSession = @import("Session.zig");
const input_support = @import("input_support.zig");

test "a frame that stops at a limit keeps the previous frame and the window open" {
    const session = try TestSession.init();
    defer session.deinit();
    try session.bootstrap();
    try session.receiveFrame(1);
    const gui = session.gui;
    const delivered = try session.draw();
    try input_support.presented(gui, delivered, true);

    const callbacks = window_callbacks.bind(gui);
    const viewport: native.Viewport = .{
        .width = gui.renderer.viewport[0],
        .height = gui.renderer.viewport[1],
        .scale = gui.renderer.scale,
    };
    var frame = std.mem.zeroes(native.Frame);

    // A window larger than the cell budget stops the frame in measurement.
    const metrics = gui.renderer.metrics;
    const huge: native.Viewport = .{
        .width = metrics.cell_width * 420,
        .height = metrics.cell_height * 220,
        .scale = viewport.scale,
    };
    try session.receiveFrame(2);
    callbacks.render(gui, huge, &frame);
    try std.testing.expectEqual(@as(u64, 0), frame.token);
    try std.testing.expect(gui.failure == null);
    try std.testing.expect(callbacks.pump(gui) >= 0);

    const reaches = &gui.app.model.limit_reaches;
    const slot = reaches.find("render.retained_max_cells").?;
    try std.testing.expectEqual(@as(u64, 1), reaches.hits[slot]);
    try std.testing.expectEqual(@as(u64, 65536), reaches.value[slot]);
    try std.testing.expectEqual(@as(u8, 1), gui.app.model.notification_center.count);

    // The frame cannot show its notice, so the title names the limit.
    var title: native.WindowTitle = .{};
    _ = try gui.windowTitle(&title);
    try std.testing.expect(std.mem.endsWith(u8, title.bytes[0..title.len], "limit reached: render.retained_max_cells"));

    // The frame that stopped is not asked for, nor measured, again until
    // what it shows or its viewport changes.
    try std.testing.expect(!gui.needs_draw);
    callbacks.render(gui, huge, &frame);
    try std.testing.expectEqual(@as(u64, 0), frame.token);
    try std.testing.expectEqual(@as(u64, 1), reaches.hits[slot]);

    // A viewport just as large measures again and counts, without a second
    // notice inside the interval.
    var taller = huge;
    taller.height += gui.renderer.metrics.cell_height;
    callbacks.render(gui, taller, &frame);
    try std.testing.expectEqual(@as(u64, 0), frame.token);
    try std.testing.expectEqual(@as(u64, 2), reaches.hits[slot]);
    try std.testing.expectEqual(@as(u8, 1), gui.app.model.notification_center.count);

    try session.receiveFrame(3);
    callbacks.render(gui, viewport, &frame);
    try std.testing.expect(frame.token != 0);
    try std.testing.expect(gui.limited == null);
    try std.testing.expect(gui.failure == null);

    _ = try gui.windowTitle(&title);
    try std.testing.expect(std.mem.indexOf(u8, title.bytes[0..title.len], "limit reached") == null);
}

test "an update event that stops at a limit is skipped and the rest of the turn runs" {
    const session = try TestSession.init();
    defer session.deinit();
    try session.bootstrap();
    const gui = session.gui;
    const callbacks = window_callbacks.bind(gui);

    try gui.driver.inbox.post(.{ .binding_timeout = error.QueueFull });
    try gui.driver.inbox.post(.{ .focus = false });
    try std.testing.expect(callbacks.pump(gui) >= 0);

    try std.testing.expect(gui.failure == null);
    try std.testing.expect(!gui.focused);
    const reaches = &gui.app.model.limit_reaches;
    const slot = reaches.find("QueueFull").?;
    try std.testing.expectEqualStrings("window_update", reaches.reachAt(slot).route);
    try std.testing.expectEqual(@as(u8, 1), gui.app.model.notification_center.count);

    // The same limit again in a later turn counts without a second notice.
    try gui.driver.inbox.post(.{ .binding_timeout = error.QueueFull });
    try std.testing.expect(callbacks.pump(gui) >= 0);
    try std.testing.expectEqual(@as(u64, 2), reaches.hits[slot]);
    try std.testing.expectEqual(@as(u8, 1), gui.app.model.notification_center.count);
}
