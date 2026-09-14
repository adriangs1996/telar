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
    try session.gui.input.drain(&session.gui.app);
    var request: native.HostRequest = .{};
    try std.testing.expect(session.gui.host.next(&request));
    try std.testing.expectEqual(@as(u32, 1), request.kind);
    try std.testing.expectEqual(@as(u64, 0), request.target_id);
    var bytes = [_]u8{'z'} ** 1025;
    try session.gui.input.accept(.{ .kind = 9, .phase = 0, .request_id = request.request_id, .generation = request.generation, .text = &bytes, .len = bytes.len });
    @memset(&bytes, 'x');
    try session.gui.input.drain(&session.gui.app);
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
    try session.gui.input.drain(&session.gui.app);
    var request: native.HostRequest = .{};
    try std.testing.expect(session.gui.host.next(&request));
    const model = session.gui.app.model.activeTabModel().?;
    const second: core.PaneId = @enumFromInt(11);
    try model.split(.{ .existing_pane = Session.pane_id, .new_pane = second, .location = Session.location, .axis = .horizontal, .area = session.gui.region.area });
    try session.gui.input.accept(.{ .kind = 9, .request_id = request.request_id, .generation = request.generation, .text = "late", .len = 4 });
    try session.gui.input.drain(&session.gui.app);
    try session.settle();
    try std.testing.expectEqual(@as(usize, 0), session.input_len);
    try std.testing.expectEqual(@as(u64, 0), session.gui.input.terminal_clipboard.request_id);
}
