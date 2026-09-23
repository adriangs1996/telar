const data = @import("model");
const input_support = @import("input_support.zig");
const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const Session = @import("Session.zig");
const native = @import("../native/native.zig");

test "GUI clipboard shortcut requests owned async text and streams a bracketed terminal paste" {
    const session = try Session.init();
    defer session.deinit();
    try session.bootstrap();
    try session.receiveFrame(1);
    try input_support.acceptNative(session.gui, .{ .kind = 4, .code = 'v', .mods = 8, .physical = 10 });
    try input_support.acceptNative(session.gui, .{ .kind = 4, .code = 'v', .mods = 8, .physical = 10, .phase = 3 });
    try input_support.pump(session.gui);
    var request: native.HostRequest = .{};
    try std.testing.expect(session.gui.host.next(&request));
    try std.testing.expectEqual(@as(u32, 1), request.kind);
    try std.testing.expectEqual(@as(u64, 0), request.target_id);
    var bytes = [_]u8{'z'} ** 1025;
    try input_support.acceptNative(session.gui, .{ .kind = 9, .phase = 0, .request_id = request.request_id, .generation = request.generation, .text = &bytes, .len = bytes.len });
    @memset(&bytes, 'x');
    try input_support.pump(session.gui);
    try session.settle();
    try std.testing.expectEqualStrings("\x1b[200~" ++ "z" ** 1025 ++ "\x1b[201~", session.input[0..session.input_len]);
    try std.testing.expectEqual(@as(usize, 0), session.gui.input_queue.len);
    try std.testing.expect(session.gui.terminal_clipboard.offset == null);
}

test "delayed terminal clipboard response cannot paste into a newly focused pane" {
    const session = try Session.init();
    defer session.deinit();
    try session.bootstrap();
    try session.receiveFrame(1);
    try input_support.acceptNative(session.gui, .{ .kind = 4, .code = 'v', .mods = 5 });
    try input_support.pump(session.gui);
    var request: native.HostRequest = .{};
    try std.testing.expect(session.gui.host.next(&request));
    const tab = session.gui.app.model.tabs.active;
    const second: core.PaneId = @enumFromInt(11);
    try data.pane_split.split(&session.gui.app.model, tab, .{ .existing_pane = Session.pane_id, .new_pane = second, .location = Session.location, .axis = .horizontal, .area = session.gui.region.area });
    try input_support.acceptNative(session.gui, .{ .kind = 9, .request_id = request.request_id, .generation = request.generation, .text = "late", .len = 4 });
    try input_support.pump(session.gui);
    try session.settle();
    try std.testing.expectEqual(@as(usize, 0), session.input_len);
    try std.testing.expectEqual(@as(u64, 0), session.gui.terminal_clipboard.request_id);
}

test "each GUI drains only its own queue and respects its own startup gate" {
    const first = try Session.init();
    defer first.deinit();
    const second = try Session.init();
    defer second.deinit();
    try first.bootstrap();
    try second.bootstrap();
    try first.receiveFrame(1);
    try second.receiveFrame(1);

    first.gui.app.model.startup.phase = .probing;
    try input_support.accept(first.gui, .{ .text = .{ .bytes = "left" } });
    try input_support.accept(second.gui, .{ .text = .{ .bytes = "right" } });
    try input_support.pump(first.gui);
    try input_support.pump(second.gui);
    try second.settle();
    try std.testing.expectEqual(@as(usize, 4), first.gui.input_queue.len);
    try std.testing.expectEqual(@as(usize, 0), first.input_len);
    try std.testing.expectEqualStrings("right", second.input[0..second.input_len]);
    try std.testing.expectEqual(@as(usize, 0), second.gui.input_queue.len);

    first.gui.app.model.startup.phase = .active;
    try input_support.pump(first.gui);
    try first.settle();
    try std.testing.expectEqualStrings("left", first.input[0..first.input_len]);
    try std.testing.expectEqualStrings("right", second.input[0..second.input_len]);
    try std.testing.expectEqual(@as(usize, 0), first.gui.input_queue.len);
}

test "GUI admission stamps geometry and invalidates only its own gestures before recovery drains" {
    const first = try Session.init();
    defer first.deinit();
    const second = try Session.init();
    defer second.deinit();
    const gui = first.gui;
    gui.pointer.configure(.{ 8, 8 }, gui.app.model.hostSize());
    const generation = gui.pointer.gesture_revision;
    const other_generation = second.gui.pointer.gesture_revision;
    try input_support.accept(gui, .{ .pointer = .{ .kind = .press, .x = 10, .y = 10 } });
    try input_support.accept(gui, .{ .scroll = .{ .delta_y = 1 } });
    const original = gui.input_queue.front().?.pointer;
    try std.testing.expectEqual(gui.pointer.revision, original.geometry_revision);
    try std.testing.expectEqual(generation, original.gesture_revision);
    const scroll = gui.input_queue.items[1].scroll;
    try std.testing.expectEqual(original.geometry_revision, scroll.geometry_revision);
    try std.testing.expectEqual(generation, scroll.gesture_revision);

    while (gui.input_queue.len < gui.input_queue.items.len - 1) {
        try input_support.accept(gui, .{ .pointer = .{ .kind = .move } });
    }

    try input_support.accept(gui, .{ .pointer = .{ .kind = .release } });
    try std.testing.expectEqual(generation + 1, gui.pointer.gesture_revision);
    try std.testing.expect(gui.input_queue.recovery.queued);
    try std.testing.expectEqual(gui.input_queue.items.len, gui.input_queue.len);
    try std.testing.expectEqual(original, gui.input_queue.front().?.pointer);
    try std.testing.expectEqual(other_generation, second.gui.pointer.gesture_revision);
    try std.testing.expectEqual(@as(usize, 0), second.gui.input_queue.len);

    try input_support.accept(gui, .{ .pointer = .{ .kind = .release } });
    try std.testing.expectEqual(generation + 2, gui.pointer.gesture_revision);
    try std.testing.expectEqual(gui.input_queue.items.len, gui.input_queue.len);
    try std.testing.expect(!try gui.acceptInput(.{ .pointer = .{ .kind = .press } }));
    try std.testing.expectEqual(generation + 2, gui.pointer.gesture_revision);
    try input_support.pump(gui);
    try std.testing.expect(gui.input_queue.recovery.queued);
    try std.testing.expect(!gui.recovery_interactions_finished);
}

test "shared routing queries distinguish key capture from eligible repetition" {
    const session = try Session.init();
    defer session.deinit();
    const app = &session.gui.app;
    try std.testing.expect(!data.key_routing.captures(app.keyRoutingAuthority()));
    try std.testing.expect(app.repeatPane() == null);
    try session.bootstrap();
    try session.receiveFrame(1);
    try std.testing.expectEqual(Session.pane_id, app.repeatPane().?);

    const tab = app.model.tabs.active;
    const second: core.PaneId = @enumFromInt(11);
    try data.pane_split.split(&app.model, tab, .{
        .existing_pane = Session.pane_id,
        .new_pane = second,
        .location = Session.location,
        .axis = .horizontal,
        .area = session.gui.region.area,
    });
    const pane = app.model.panes.find(second).?;
    pane.attached = true;
    try std.testing.expectEqual(second, app.repeatPane().?);
    pane.attached = false;
    try std.testing.expect(app.repeatPane() == null);
    try std.testing.expect(!data.key_routing.captures(app.keyRoutingAuthority()));
    pane.attached = true;

    app.model.name_prompt.begin(.create_workspace);
    try std.testing.expect(data.key_routing.captures(app.keyRoutingAuthority()));
    try std.testing.expect(app.repeatPane() == null);
    _ = app.model.name_prompt.apply(.cancel);
    try std.testing.expectEqual(second, app.repeatPane().?);

    try std.testing.expect(app.model.enterCopyMode());
    try std.testing.expect(!data.key_routing.captures(app.keyRoutingAuthority()));
    try std.testing.expect(app.repeatPane() == null);
}
