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
    var capture = Capture.begin(app, .{ .x = view.content.x, .y = view.content.y, .kind = .press }).?;
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

test "native child release crosses a newly opened prompt only with its acquired lease" {
    const Capture = @import("../input/PointerCapture.zig");
    const session = try Session.init();
    defer session.deinit();
    try session.bootstrap();
    try session.receiveFrame(1);
    try session.settle();
    const app = &session.gui.app;
    const model = app.model.activeTabModel().?;
    const pane = model.find(Session.pane_id).?;
    pane.mouse = .{ .sgr = true, .tracking = .button };
    const view = model.viewForPane(pane.id, session.gui.region.area).?;
    const press: client.Mouse = .{ .x = view.content.x, .y = view.content.y, .kind = .press };
    var capture = Capture.begin(app, press).?;
    try std.testing.expect(client.controllers.name_prompts.beginActiveTabRename(app));
    try std.testing.expect(app.model.planPaneInput(.{ .pane = pane.id }) == null);
    var release = press;
    release.kind = .release;
    try capture.deliver(app, release);
    const request = try core.decodeClient(session.pending.?);
    try std.testing.expectEqual(pane.id, request.pane_input.pane_id);
    try std.testing.expect(std.mem.endsWith(u8, request.pane_input.bytes, "m"));
    try session.settle();
}

test "native pointer rejects a newer layout even before a GPU flight starts" {
    const session = try Session.init();
    defer session.deinit();
    try session.bootstrap();
    try session.receiveFrame(1);
    const token = try session.gui.prepare(&session.renderer);
    try session.gui.complete(token, true);
    try session.settle();
    const app = &session.gui.app;
    const model = app.model.activeTabModel().?;
    session.gui.input.setGeometry(.{ 0, 0 }, app.model.hostSize());
    try model.split(.{ .existing_pane = Session.pane_id, .new_pane = @enumFromInt(11), .location = Session.location, .axis = .horizontal, .area = session.gui.region.area });
    try std.testing.expect(!app.presentation.inFlight());
    try session.gui.input.accept(.{ .kind = 6, .code = 1, .x = 10, .y = 10 });
    try session.gui.input.accept(.{ .kind = 6, .code = 2, .x = 10, .y = 10 });
    try session.gui.input.drain(app);
    try session.settle();
    try std.testing.expect(app.model.pointerSelection() == null);
    try std.testing.expectEqual(@as(usize, 0), session.input_len);
}

test "native focus loss releases an acquired child mouse gesture" {
    const session = try Session.init();
    defer session.deinit();
    try session.bootstrap();
    try session.receiveFrame(1);
    const app = &session.gui.app;
    const model = app.model.activeTabModel().?;
    const pane = model.find(Session.pane_id).?;
    pane.mouse = .{ .sgr = true, .tracking = .button };
    const token = try session.gui.prepare(&session.renderer);
    try session.gui.complete(token, true);
    try session.settle();
    session.gui.input.setGeometry(.{ 0, 0 }, app.model.hostSize());
    const view = model.viewForPane(pane.id, session.gui.region.area).?;
    const x = @as(f64, @floatFromInt(view.content.x)) * app.model.hostSize().cell_width_px + 1;
    const y = @as(f64, @floatFromInt(view.content.y)) * app.model.hostSize().cell_height_px + 1;
    try session.gui.input.accept(.{ .kind = 6, .code = 1, .x = x, .y = y });
    try session.gui.input.drain(app);
    try session.settle();
    try std.testing.expect(session.gui.input.pointer.owners[0] == .child);
    try session.gui.input.cancelPointer(app);
    try session.settle();
    try std.testing.expect(session.gui.input.pointer.owners[0] == .shared);
    try std.testing.expect(std.mem.endsWith(u8, session.input[0..session.input_len], "m"));
}

test "native mouse release reaches its original tab and a pane hidden by fullscreen" {
    const session = try Session.init();
    defer session.deinit();
    try prepareMouse(session);
    const app = &session.gui.app;
    const input = &session.gui.input;
    const press = pointerPress(session);
    try input.accept(press);
    try drainInput(session);
    const second_tab: core.TabId = @enumFromInt(2);
    _ = try app.model.workspace.addCreated(.{ .location = .{ .workspace = Session.location.workspace, .tab_id = second_tab }, .position = 1, .label = "second", .root_pane_id = @enumFromInt(20) }, app.model.hostSize());
    var release = press;
    release.code = 2;
    try input.accept(release);
    try input.drain(app);
    const request = try core.decodeClient(session.pending.?);
    try std.testing.expectEqual(Session.pane_id, request.pane_input.pane_id);
    try std.testing.expect(std.mem.endsWith(u8, request.pane_input.bytes, "m"));
    try session.settle();
    try std.testing.expectEqual(second_tab, app.model.activeTabLocation().?.tab_id);

    _ = app.model.workspace.select(Session.location.tab_id);
    const model = app.model.activeTabModel().?;
    const second_pane: core.PaneId = @enumFromInt(11);
    try model.split(.{ .existing_pane = Session.pane_id, .new_pane = second_pane, .location = Session.location, .axis = .horizontal, .area = app.geometry().area });
    _ = model.layout.focusPane(Session.pane_id);
    _ = model.layout.toggleFullscreen();
    const token = try session.gui.prepare(&session.renderer);
    try session.gui.complete(token, true);
    try session.settle();
    try input.accept(pointerPress(session));
    try drainInput(session);
    _ = model.layout.focusPane(second_pane);
    try std.testing.expect(model.viewForPane(Session.pane_id, app.geometry().area) == null);
    try input.accept(release);
    try input.drain(app);
    const hidden_request = try core.decodeClient(session.pending.?);
    try std.testing.expectEqual(Session.pane_id, hidden_request.pane_input.pane_id);
    try std.testing.expect(std.mem.endsWith(u8, hidden_request.pane_input.bytes, "m"));
    try session.settle();
    try std.testing.expectEqual(second_pane, model.layout.focused().?);
    try std.testing.expect(input.pointer.owners[0] == .shared);
}

test "native saturated mouse release cancels captured owners and admits a fresh gesture" {
    const session = try Session.init();
    defer session.deinit();
    try prepareMouse(session);
    const gui = session.gui;
    const input = &gui.input;
    const press = pointerPress(session);
    try input.accept(press);
    try drainInput(session);
    try std.testing.expect(input.pointer.owners[0] == .child);
    _ = gui.chrome.pointer(.{ .x = 0, .y = 0, .kind = .press, .button = 2 });
    gui.app.model.name_prompt.begin(.create_workspace);
    const token = try gui.prepare(&session.renderer);
    try gui.complete(token, true);
    _ = gui.overlays.pointer(.{ .x = 0, .y = 0, .kind = .press, .button = 1 });
    try std.testing.expect(gui.chrome.gesture_button != null and gui.overlays.gesture != null);
    try saturate(input);
    var release = press;
    release.code = 2;
    try input.accept(release);
    try input.accept(release);
    try std.testing.expectEqual(@as(usize, 1024), input.len);
    try std.testing.expectError(error.NativeInputFull, input.accept(press));
    try drainInput(session);
    try std.testing.expect(input.pointer.owners[0] == .shared);
    try std.testing.expect(gui.chrome.gesture_button == null and gui.overlays.gesture == null);
    try std.testing.expect(std.mem.endsWith(u8, session.input[0..session.input_len], "m"));

    _ = gui.app.model.name_prompt.apply(.cancel);
    const closed = try gui.prepare(&session.renderer);
    try gui.complete(closed, true);
    try session.settle();
    try input.accept(press);
    try drainInput(session);
    try std.testing.expect(input.pointer.owners[0] == .child);
    try input.accept(release);
    try drainInput(session);
    try std.testing.expect(input.pointer.owners[0] == .shared);
}

test "native saturated key releases preserve order and finish before another press" {
    const session = try Session.init();
    defer session.deinit();
    try prepareMouse(session);
    const input = &session.gui.input;
    session.gui.app.model.workspace.findPane(Session.pane_id).?.input_modes.kitty_keyboard_flags = 10;
    try input.accept(.{ .kind = 4, .code = 'k', .physical = 9 });
    try input.accept(.{ .kind = 4, .code = 'j', .physical = 4 });
    try drainInput(session);
    const before = session.input_len;
    try saturate(input);
    try input.accept(.{ .kind = 4, .code = 'k', .physical = 9, .phase = 3 });
    try input.accept(.{ .kind = 4, .code = 'j', .physical = 4, .phase = 3 });
    try input.accept(.{ .kind = 4, .code = 'j', .physical = 4, .phase = 3 });
    try std.testing.expectEqual(@as(usize, 1024), input.len);
    try std.testing.expectEqual(@as(usize, 2), input.recovery.len);
    try std.testing.expectError(error.NativeInputFull, input.accept(.{ .kind = 4, .code = 'k', .physical = 9 }));
    try drainInput(session);
    try std.testing.expectEqualStrings("\x1b[107;1:3u\x1b[106;1:3u", session.input[before..session.input_len]);
    try std.testing.expectEqual(@as(usize, 0), input.router.leases.count());
    const recovered = session.input_len;
    try input.accept(.{ .kind = 4, .code = 'k', .physical = 9 });
    try input.accept(.{ .kind = 4, .code = 'k', .physical = 9, .phase = 3 });
    try drainInput(session);
    try std.testing.expectEqualStrings("\x1b[107u\x1b[107;1:3u", session.input[recovered..session.input_len]);
    try std.testing.expectEqual(@as(usize, 0), input.router.leases.count());
}

fn prepareMouse(session: *Session) !void {
    try session.bootstrap();
    try session.receiveFrame(1);
    session.gui.app.model.workspace.findPane(Session.pane_id).?.mouse = .{ .sgr = true, .tracking = .button };
    const token = try session.gui.prepare(&session.renderer);
    try session.gui.complete(token, true);
    try session.settle();
    session.gui.input.setGeometry(.{ 0, 0 }, session.gui.app.model.hostSize());
}

fn pointerPress(session: *Session) @import("../native/native.zig").InputEvent {
    const model = session.gui.app.model.activeTabModel().?;
    const view = model.viewForPane(Session.pane_id, session.gui.region.area).?;
    const size = session.gui.app.model.hostSize();
    return .{ .kind = 6, .code = 1, .x = @as(f64, @floatFromInt(view.content.x)) * size.cell_width_px + 1, .y = @as(f64, @floatFromInt(view.content.y)) * size.cell_height_px + 1 };
}

fn saturate(input: *NativeInput) !void {
    for (0..1023) |_| {
        try input.accept(.{ .kind = 6, .code = 6 });
    }
}

fn drainInput(session: *Session) !void {
    var turns: usize = 0;
    while (session.gui.input.len != 0) : (turns += 1) {
        if (turns > 1024) {
            return error.UnboundedInputRecovery;
        }

        try session.gui.inputReady();
        try session.settle();
    }
}
