const std = @import("std");
const core = @import("telar-core");
const Session = @import("Session.zig");
const native = @import("../native/native.zig");

test "GUI clipboard shortcut requests owned async text and streams a bracketed terminal paste" {
    const session = try Session.init();
    defer session.deinit();
    try session.bootstrap();
    try session.receiveFrame(1);
    try session.gui.input.accept(.{ .kind = 4, .code = 'v', .mods = 8, .physical = 10 });
    try session.gui.input.accept(.{ .kind = 4, .code = 'v', .mods = 8, .physical = 10, .phase = 3 });
    try session.gui.drainInput();
    var request: native.HostRequest = .{};
    try std.testing.expect(session.gui.host.next(&request));
    try std.testing.expectEqual(@as(u32, 1), request.kind);
    try std.testing.expectEqual(@as(u64, 0), request.target_id);
    var bytes = [_]u8{'z'} ** 1025;
    try session.gui.input.accept(.{ .kind = 9, .phase = 0, .request_id = request.request_id, .generation = request.generation, .text = &bytes, .len = bytes.len });
    @memset(&bytes, 'x');
    try session.gui.drainInput();
    try session.settle();
    try std.testing.expectEqualStrings("\x1b[200~" ++ "z" ** 1025 ++ "\x1b[201~", session.input[0..session.input_len]);
    try std.testing.expectEqual(@as(usize, 0), session.gui.input.len);
    try std.testing.expect(session.gui.input.clipboard_offset == null);
}

test "delayed terminal clipboard response cannot paste into a newly focused pane" {
    const session = try Session.init();
    defer session.deinit();
    try session.bootstrap();
    try session.receiveFrame(1);
    try session.gui.input.accept(.{ .kind = 4, .code = 'v', .mods = 5 });
    try session.gui.drainInput();
    var request: native.HostRequest = .{};
    try std.testing.expect(session.gui.host.next(&request));
    const model = session.gui.app.model.activeTabModel().?;
    const second: core.PaneId = @enumFromInt(11);
    try model.split(.{ .existing_pane = Session.pane_id, .new_pane = second, .location = Session.location, .axis = .horizontal, .area = session.gui.region.area });
    try session.gui.input.accept(.{ .kind = 9, .request_id = request.request_id, .generation = request.generation, .text = "late", .len = 4 });
    try session.gui.drainInput();
    try session.settle();
    try std.testing.expectEqual(@as(usize, 0), session.input_len);
    try std.testing.expectEqual(@as(u64, 0), session.gui.input.terminal_clipboard.request_id);
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

    first.gui.app.startup.phase = .probing;
    try first.gui.input.acceptEvent(.{ .text = .{ .bytes = "left" } });
    try second.gui.input.acceptEvent(.{ .text = .{ .bytes = "right" } });
    try first.gui.drainInput();
    try second.gui.drainInput();
    try second.settle();
    try std.testing.expectEqual(@as(usize, 4), first.gui.input.len);
    try std.testing.expectEqual(@as(usize, 0), first.input_len);
    try std.testing.expectEqualStrings("right", second.input[0..second.input_len]);
    try std.testing.expectEqual(@as(usize, 0), second.gui.input.len);

    first.gui.app.startup.phase = .active;
    try first.gui.drainInput();
    try first.settle();
    try std.testing.expectEqualStrings("left", first.input[0..first.input_len]);
    try std.testing.expectEqualStrings("right", second.input[0..second.input_len]);
    try std.testing.expectEqual(@as(usize, 0), first.gui.input.len);
}
