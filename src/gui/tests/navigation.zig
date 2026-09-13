const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const Session = @import("Session.zig");
const NativeInput = @import("../NativeInput.zig");
const routing = @import("../input/router.zig");

const ActionCapture = @import("ActionCapture.zig");

test "native semantic router resolves every TUI default action" {
    const defaults = try client.default_bindings.load(client.default_prefix);
    for (defaults) |binding| {
        var router = try routing.build(.{ .prefix = client.default_prefix, .bindings = &.{}, .escape_timeout_ns = 1, .sequence_timeout_ns = 1 });
        var capture: ActionCapture = .{};
        for (binding.keys[0..binding.len]) |key| {
            _ = try router.routeEvent(.{ .key = key, .raw = "", .now_ns = 1 }, &capture);
        }

        try std.testing.expectEqualDeep(binding.action, capture.value.?);
        try std.testing.expectEqual(@as(usize, 0), capture.keys);
    }
}

test "native rename prompt receives pasted text without leaking to the child" {
    const session = try Session.init();
    defer session.deinit();
    try session.bootstrap();
    try session.receiveFrame(1);
    try chord(session, "T");
    try std.testing.expect(session.gui.app.model.name_prompt.active());
    const text = "new workspace";
    try session.gui.input.accept(.{ .kind = 2, .text = text.ptr, .len = text.len });
    try session.gui.input.drain(&session.gui.app);
    try session.settle();
    try std.testing.expectEqualStrings("main" ++ text, session.gui.app.model.name_prompt.currentConst().?.field.text());
    try std.testing.expectEqual(@as(usize, 0), session.input_len);
}

test "native custom prefix navigates pane focus fullscreen and copy mode" {
    const session = try Session.init();
    defer session.deinit();
    try session.bootstrap();
    try session.receiveFrame(1);
    session.gui.input.adopt(&session.gui.app, .{ .prefix = try client.parseKey("ctrl+space"), .bindings = &.{}, .escape_timeout_ns = 1, .sequence_timeout_ns = 1 });
    const model = session.gui.app.model.activeTabModel().?;
    const second: core.PaneId = @enumFromInt(11);
    try model.split(.{ .existing_pane = Session.pane_id, .new_pane = second, .location = Session.location, .axis = .horizontal, .area = session.gui.region.area });
    try session.gui.input.accept(.{ .kind = 4, .code = ' ', .mods = 4 });
    try session.gui.input.accept(.{ .kind = 3, .code = 7 });
    try session.gui.input.drain(&session.gui.app);
    try session.settle();
    try std.testing.expectEqual(Session.pane_id, model.layout.focused().?);
    try customChord(session, "z");
    try std.testing.expect(model.layout.isFullscreen());
    try customChord(session, "z");
    try std.testing.expect(!model.layout.isFullscreen());
    try customChord(session, "[");
    try std.testing.expect(session.gui.app.model.copyModeActive());
    try std.testing.expectEqual(@as(usize, 0), session.input_len);
}

fn chord(session: *Session, text: []const u8) !void {
    try session.gui.input.accept(.{ .kind = 4, .code = 'b', .mods = 4 });
    try session.gui.input.accept(.{ .kind = 1, .text = text.ptr, .len = text.len });
    try session.gui.input.drain(&session.gui.app);
    try session.settle();
}

fn customChord(session: *Session, text: []const u8) !void {
    try session.gui.input.accept(.{ .kind = 4, .code = ' ', .mods = 4 });
    try session.gui.input.accept(.{ .kind = 1, .text = text.ptr, .len = text.len });
    try session.gui.input.drain(&session.gui.app);
    try session.settle();
}

test "native child drag keeps its pane across focus and ignores replacement attachments" {
    const Capture = @import("../input/PointerCapture.zig");
    const session = try Session.init();
    defer session.deinit();
    try session.bootstrap();
    try session.receiveFrame(1);
    try session.settle();
    const app = &session.gui.app;
    const model = app.model.activeTabModel().?;
    const second: core.PaneId = @enumFromInt(11);
    try model.split(.{ .existing_pane = Session.pane_id, .new_pane = second, .location = Session.location, .axis = .horizontal, .area = session.gui.region.area });
    _ = model.layout.focusPane(Session.pane_id);
    const pane = model.find(Session.pane_id).?;
    pane.mouse = .{ .sgr = true, .tracking = .button };
    const view = model.viewForPane(pane.id, session.gui.region.area).?;
    const capture = Capture.begin(app, .{ .x = view.content.x, .y = view.content.y, .kind = .press }).?;
    _ = model.layout.focusPane(second);
    try capture.deliver(app, .{ .x = session.gui.region.area.w - 1, .y = view.content.y, .raw_x = 999, .raw_y = 999, .kind = .drag, .button = 32 });
    const request = try core.decodeClient(session.pending.?);
    try std.testing.expectEqual(pane.id, request.pane_input.pane_id);
    try std.testing.expectEqual(second, model.layout.focused().?);
    try session.settle();
    const before = session.input_len;
    pane.attachment_generation +%= 1;
    try capture.deliver(app, .{ .x = view.content.x, .y = view.content.y, .kind = .release });
    try session.settle();
    try std.testing.expectEqual(before, session.input_len);
}

test "native pointer rejects queued presses after geometry replacement" {
    const session = try Session.init();
    defer session.deinit();
    try session.bootstrap();
    const app = &session.gui.app;
    session.gui.input.setGeometry(.{ 0, 0 }, app.model.hostSize());
    try session.gui.input.accept(.{ .kind = 6, .code = 1, .x = 20, .y = 20 });
    session.gui.input.setGeometry(.{ 8, 8 }, app.model.hostSize());
    try session.gui.input.accept(.{ .kind = 6, .code = 2, .x = 20, .y = 20 });
    try session.gui.input.drain(app);
    try session.settle();
    try std.testing.expect(app.model.pointerSelection() == null);
    try std.testing.expectEqual(@as(usize, 0), session.input_len);
}

test "native bindings preserve ownership through hot reload and matching release" {
    const session = try Session.init();
    defer session.deinit();
    try session.bootstrap();
    const app = &session.gui.app;
    const binding = try client.config_model.ConfiguredBinding.parse(&.{"ctrl+k"}, .toggle_workspace_list);
    session.gui.input.adopt(app, .{ .prefix = client.default_prefix, .bindings = &.{binding}, .escape_timeout_ns = 1, .sequence_timeout_ns = 1 });
    try session.gui.input.accept(.{ .kind = 4, .code = 'k', .mods = 4, .physical = 9 });
    try session.gui.input.drain(app);
    session.gui.input.adopt(app, .{ .prefix = client.default_prefix, .bindings = &.{}, .escape_timeout_ns = 1, .sequence_timeout_ns = 1 });
    try session.gui.input.accept(.{ .kind = 4, .code = 'k', .physical = 9, .phase = 2 });
    try session.gui.input.accept(.{ .kind = 4, .code = 'k', .physical = 9, .phase = 3 });
    try session.gui.input.drain(app);
    try session.settle();
    try std.testing.expectEqual(@as(usize, 0), session.input_len);
}
