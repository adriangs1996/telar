const native = @import("../native/native.zig");
const data = @import("model");
const input_support = @import("input_support.zig");
const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const Session = @import("Session.zig");
const GuiClient = @import("../GuiClient.zig");
const routing = @import("../input/router.zig");

const ActionCapture = @import("ActionCapture.zig");

test "update processes a horizontal split shortcut and its correlated runtime reply" {
    const session = try Session.init();
    defer session.deinit();
    try session.bootstrap();
    const gui = session.gui;
    const app = &gui.app;
    const before = app.model.version();
    const request_area = app.geometry().area;
    try std.testing.expect(try gui.acceptInput(
        .{
            .key = .{
                .code = data.keybind.default_prefix.code,
                .mods = .{
                    .ctrl = true,
                },
            },
        },
    ));
    try std.testing.expect(try gui.acceptInput(.{ .text = .{ .bytes = "%" } }));

    try std.testing.expectEqual(@as(?u8, null), try gui.update());
    try session.settle();
    try std.testing.expectEqual(@as(usize, 1), session.pane_creation_count);
    try std.testing.expectEqualDeep(before, app.model.version());
    const request = (try core.decodeClient(session.pane_creation_wire[0..session.pane_creation_len])).create_pane;
    try std.testing.expectEqual(Session.pane_id, request.launch.cwd_source.?);
    try std.testing.expectEqualDeep(Session.location, request.location);
    const created: core.PaneId = @enumFromInt(21);
    var buffer: [128]u8 = undefined;
    const payload = try core.encodePaneOpened(&buffer, .{
        .request_id = request.request_id,
        .pane_id = created,
        .location = request.location,
        .created = true,
    });
    const response = try data.RuntimeMessage.decode(std.testing.io, payload);
    try app.startRuntimeRead();
    try session.gui.driver.inbox.post(
        .{
            .server = &response,
        },
    );

    try std.testing.expectEqual(@as(?u8, null), try gui.update());
    try session.settle();
    try std.testing.expect(!app.request_lifecycle.tracker.has(.pane_operation));
    try std.testing.expect(app.model.workspace.findPane(created).?.attached);
    try std.testing.expectEqual(created, app.model.workspace.active().?.model.layout.focused().?);
    try std.testing.expectEqual(before.panes + 1, app.model.version().panes);
    const geometry = app.model.workspace.active().?.model.layoutSnapshot(request_area);
    const first = geometry.find(Session.pane_id).?.outer;
    const second = geometry.find(created).?.outer;
    try std.testing.expectEqual(first.y, second.y);
    try std.testing.expect(first.x < second.x);
}

test "native semantic router resolves every TUI default action" {
    const defaults = try client.default_bindings.load(data.keybind.default_prefix);
    for (defaults) |binding| {
        var router = try routing.build(
            .{
                .prefix = data.keybind.default_prefix,
                .bindings = &.{},
                .escape_timeout_ns = 1,
                .sequence_timeout_ns = 1,
            },
        );
        var capture: ActionCapture = .{};
        for (binding.keys[0..binding.len]) |key| {
            switch (router.routeEvent(.{ .key = key, .raw = "", .now_ns = 1 }, .{})) {
                .action => |request| {
                    _ = try capture.action(request.value);
                },
                .pending, .discard => {},
                else => return error.UnexpectedForward,
            }
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
    try input_support.acceptNative(session.gui, .{ .kind = 2, .text = text.ptr, .len = text.len });
    try input_support.pump(session.gui);
    try session.settle();
    try std.testing.expectEqualStrings("shell" ++ text, session.gui.app.model.name_prompt.currentConst().?.field.text());
    try std.testing.expectEqual(@as(usize, 0), session.input_len);
}

test "native custom prefix navigates pane focus fullscreen and copy mode" {
    const session = try Session.init();
    defer session.deinit();
    try session.bootstrap();
    try session.receiveFrame(1);
    session.gui.adoptBindings(
        .{
            .prefix = try data.chord.parseKey("ctrl+space"),
            .bindings = &.{},
            .escape_timeout_ns = 1,
            .sequence_timeout_ns = 1,
        },
    );
    const model = session.gui.app.model.activeTabModel().?;
    const second: core.PaneId = @enumFromInt(11);
    try model.split(.{ .existing_pane = Session.pane_id, .new_pane = second, .location = Session.location, .axis = .horizontal, .area = session.gui.region.area });
    try input_support.acceptNative(session.gui, .{ .kind = 4, .code = ' ', .mods = 4 });
    try input_support.acceptNative(session.gui, .{ .kind = 3, .code = 7 });
    try input_support.pump(session.gui);
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
    try input_support.acceptNative(session.gui, .{ .kind = 4, .code = 'b', .mods = 4 });
    try input_support.acceptNative(session.gui, .{ .kind = 1, .text = text.ptr, .len = text.len });
    try input_support.pump(session.gui);
    try session.settle();
}

fn customChord(session: *Session, text: []const u8) !void {
    try input_support.acceptNative(session.gui, .{ .kind = 4, .code = ' ', .mods = 4 });
    try input_support.acceptNative(session.gui, .{ .kind = 1, .text = text.ptr, .len = text.len });
    try input_support.pump(session.gui);
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
    session.gui.pointer.configure(.{ 0, 0 }, app.model.hostSize());
    try input_support.acceptNative(session.gui, .{ .kind = 6, .code = 1, .x = 20, .y = 20 });
    session.gui.pointer.configure(.{ 8, 8 }, app.model.hostSize());
    try input_support.acceptNative(session.gui, .{ .kind = 6, .code = 2, .x = 20, .y = 20 });
    try input_support.pump(session.gui);
    try session.settle();
    try std.testing.expect(app.model.pointerSelection() == null);
    try std.testing.expectEqual(@as(usize, 0), session.input_len);
}

test "native bindings preserve ownership through hot reload and matching release" {
    const session = try Session.init();
    defer session.deinit();
    try session.bootstrap();
    const binding = try data.config_values.ConfiguredBinding.parse(&.{"ctrl+k"}, .toggle_workspace_list);
    session.gui.adoptBindings(
        .{
            .prefix = data.keybind.default_prefix,
            .bindings = &.{
                binding,
            },
            .escape_timeout_ns = 1,
            .sequence_timeout_ns = 1,
        },
    );
    try input_support.acceptNative(session.gui, .{ .kind = 4, .code = 'k', .mods = 4, .physical = 9 });
    try input_support.pump(session.gui);
    session.gui.adoptBindings(
        .{
            .prefix = data.keybind.default_prefix,
            .bindings = &.{},
            .escape_timeout_ns = 1,
            .sequence_timeout_ns = 1,
        },
    );
    try input_support.acceptNative(session.gui, .{ .kind = 4, .code = 'k', .physical = 9, .phase = 2 });
    try input_support.acceptNative(session.gui, .{ .kind = 4, .code = 'k', .physical = 9, .phase = 3 });
    try input_support.pump(session.gui);
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
    const press: data.Mouse = .{
        .x = view.content.x,
        .y = view.content.y,
        .kind = .press,
    };
    var capture = Capture.begin(app, press).?;
    try std.testing.expect(app.openNamePrompt(.rename_active_tab));
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
    const token = try session.draw();
    try input_support.presented(
        session.gui,
        token,
        true,
    );
    try session.settle();
    const app = &session.gui.app;
    const model = app.model.activeTabModel().?;
    session.gui.pointer.configure(.{ 0, 0 }, app.model.hostSize());
    try model.split(.{ .existing_pane = Session.pane_id, .new_pane = @enumFromInt(11), .location = Session.location, .axis = .horizontal, .area = session.gui.region.area });
    try std.testing.expect(!app.presentation.inFlight());
    try input_support.acceptNative(session.gui, .{ .kind = 6, .code = 1, .x = 10, .y = 10 });
    try input_support.acceptNative(session.gui, .{ .kind = 6, .code = 2, .x = 10, .y = 10 });
    try input_support.pump(session.gui);
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
    const token = try session.draw();
    try input_support.presented(
        session.gui,
        token,
        true,
    );
    try session.settle();
    session.gui.pointer.configure(session.gui.renderer.origin, app.model.hostSize());
    const view = model.viewForPane(pane.id, session.gui.region.area).?;
    const x = @as(f64, @floatFromInt(view.content.x)) * app.model.hostSize().cell_width_px + @as(f64, @floatFromInt(session.gui.renderer.origin[0])) + 1;
    const y = @as(f64, @floatFromInt(view.content.y)) * app.model.hostSize().cell_height_px + @as(f64, @floatFromInt(session.gui.renderer.origin[1])) + 1;
    try input_support.acceptNative(session.gui, .{ .kind = 6, .code = 1, .x = x, .y = y });
    try input_support.pump(session.gui);
    try session.settle();
    try std.testing.expect(session.gui.pointer.owners[0] == .child);
    try input_support.focus(session.gui, false);
    try session.settle();
    try std.testing.expect(session.gui.pointer.owners[0] == .shared);
    try std.testing.expect(std.mem.endsWith(u8, session.input[0..session.input_len], "m"));
}

test "native mouse release reaches its original tab and a pane hidden by fullscreen" {
    const session = try Session.init();
    defer session.deinit();
    try prepareMouse(session);
    const app = &session.gui.app;
    const gui = session.gui;
    const press = pointerPress(session);
    try input_support.acceptNative(gui, press);
    try drainInput(session);
    const second_tab: core.TabId = @enumFromInt(2);
    _ = try app.model.workspace.addCreated(.{ .location = .{ .workspace = Session.location.workspace, .tab_id = second_tab }, .position = 1, .label = "second", .root_pane_id = @enumFromInt(20) }, app.model.hostSize());
    var release = press;
    release.code = 2;
    try input_support.acceptNative(gui, release);
    try input_support.pump(session.gui);
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
    const token = try session.draw();
    try input_support.presented(
        session.gui,
        token,
        true,
    );
    try session.settle();
    try input_support.acceptNative(gui, pointerPress(session));
    try drainInput(session);
    _ = model.layout.focusPane(second_pane);
    try std.testing.expect(model.viewForPane(Session.pane_id, app.geometry().area) == null);
    try input_support.acceptNative(gui, release);
    try input_support.pump(session.gui);
    const hidden_request = try core.decodeClient(session.pending.?);
    try std.testing.expectEqual(Session.pane_id, hidden_request.pane_input.pane_id);
    try std.testing.expect(std.mem.endsWith(u8, hidden_request.pane_input.bytes, "m"));
    try session.settle();
    try std.testing.expectEqual(second_pane, model.layout.focused().?);
    try std.testing.expect(gui.pointer.owners[0] == .shared);
}

test "native saturated mouse release cancels captured owners and admits a fresh gesture" {
    const session = try Session.init();
    defer session.deinit();
    try prepareMouse(session);
    const gui = session.gui;
    const press = pointerPress(session);
    try input_support.acceptNative(gui, press);
    try drainInput(session);
    try std.testing.expect(gui.pointer.owners[0] == .child);
    _ = gui.chrome.bandPointer(.{ .kind = .press, .button = .right, .x = 1, .y = 1 });
    gui.app.model.name_prompt.begin(.create_workspace);
    const token = try session.draw();
    try input_support.presented(
        gui,
        token,
        true,
    );
    _ = gui.overlays.pointer(.{ .x = 0, .y = 0, .kind = .press, .button = 1 });
    try std.testing.expect(gui.chrome.band_gesture != null and gui.overlays.gesture != null);
    try saturate(gui);
    var release = press;
    release.code = 2;
    try input_support.acceptNative(gui, release);
    try input_support.acceptNative(gui, release);
    try std.testing.expectEqual(@as(usize, 1024), gui.input_queue.len);
    try std.testing.expectError(error.InputRejected, input_support.acceptNative(gui, press));
    try drainInput(session);
    try std.testing.expect(gui.pointer.owners[0] == .shared);
    try std.testing.expect(gui.chrome.band_gesture == null and gui.overlays.gesture == null);
    try std.testing.expect(std.mem.endsWith(u8, session.input[0..session.input_len], "m"));

    _ = gui.app.model.name_prompt.apply(.cancel);
    const closed = try session.draw();
    try input_support.presented(
        gui,
        closed,
        true,
    );
    try session.settle();
    try input_support.acceptNative(gui, press);
    try drainInput(session);
    try std.testing.expect(gui.pointer.owners[0] == .child);
    try input_support.acceptNative(gui, release);
    try drainInput(session);
    try std.testing.expect(gui.pointer.owners[0] == .shared);
}

test "native saturated key releases preserve order and finish before another press" {
    const session = try Session.init();
    defer session.deinit();
    try prepareMouse(session);
    const gui = session.gui;
    session.gui.app.model.workspace.findPane(Session.pane_id).?.input_modes.kitty_keyboard_flags = 10;
    try input_support.acceptNative(gui, .{ .kind = 4, .code = 'k', .physical = 9 });
    try input_support.acceptNative(gui, .{ .kind = 4, .code = 'j', .physical = 4 });
    try drainInput(session);
    const before = session.input_len;
    try saturate(gui);
    try input_support.acceptNative(gui, .{ .kind = 4, .code = 'k', .physical = 9, .phase = 3 });
    try input_support.acceptNative(gui, .{ .kind = 4, .code = 'j', .physical = 4, .phase = 3 });
    try input_support.acceptNative(gui, .{ .kind = 4, .code = 'j', .physical = 4, .phase = 3 });
    try std.testing.expectEqual(@as(usize, 1024), gui.input_queue.len);
    try std.testing.expectEqual(@as(usize, 2), gui.input_queue.recovery.len);
    try std.testing.expectError(error.InputRejected, input_support.acceptNative(gui, .{ .kind = 4, .code = 'k', .physical = 9 }));
    try drainInput(session);
    try std.testing.expectEqualStrings("\x1b[107;1:3u\x1b[106;1:3u", session.input[before..session.input_len]);
    try std.testing.expectEqual(@as(usize, 0), gui.router.leases.count());
    const recovered = session.input_len;
    try input_support.acceptNative(gui, .{ .kind = 4, .code = 'k', .physical = 9 });
    try input_support.acceptNative(gui, .{ .kind = 4, .code = 'k', .physical = 9, .phase = 3 });
    try drainInput(session);
    try std.testing.expectEqualStrings("\x1b[107u\x1b[107;1:3u", session.input[recovered..session.input_len]);
    try std.testing.expectEqual(@as(usize, 0), gui.router.leases.count());
}

fn prepareMouse(session: *Session) !void {
    try session.bootstrap();
    try session.receiveFrame(1);
    session.gui.app.model.workspace.findPane(Session.pane_id).?.mouse = .{ .sgr = true, .tracking = .button };
    const token = try session.draw();
    try input_support.presented(
        session.gui,
        token,
        true,
    );
    try session.settle();
    session.gui.pointer.configure(session.gui.renderer.origin, session.gui.app.model.hostSize());
}

fn pointerPress(session: *Session) native.InputEvent {
    const model = session.gui.app.model.activeTabModel().?;
    const view = model.viewForPane(Session.pane_id, session.gui.region.area).?;
    const size = session.gui.app.model.hostSize();
    return .{
        .kind = 6,
        .code = 1,
        .x = @as(f64, @floatFromInt(view.content.x)) * size.cell_width_px + @as(f64, @floatFromInt(session.gui.renderer.origin[0])) + 1,
        .y = @as(f64, @floatFromInt(view.content.y)) * size.cell_height_px + @as(f64, @floatFromInt(session.gui.renderer.origin[1])) + 1,
    };
}

fn saturate(gui: *GuiClient) !void {
    for (0..1023) |_| {
        try input_support.acceptNative(gui, .{ .kind = 6, .code = 6 });
    }
}

fn drainInput(session: *Session) !void {
    var turns: usize = 0;
    while (session.gui.input_queue.len != 0) : (turns += 1) {
        if (turns > 1024) {
            return error.UnboundedInputRecovery;
        }

        try input_support.pump(session.gui);
        try session.settle();
    }
}

test "native held keys repeat into legacy and Kitty children and stop after release" {
    const session = try Session.init();
    defer session.deinit();
    try session.bootstrap();
    try session.receiveFrame(1);
    const fixtures = .{
        .{ native.InputEvent{ .kind = 1, .text = "j".ptr, .len = 1, .physical = 39 }, "jjj", "\x1b[106u\x1b[106;1:2u\x1b[106;1:2u\x1b[106;1:3u" },
        .{ native.InputEvent{ .kind = 3, .code = 6, .physical = 126 }, "\x1b[B\x1b[B\x1b[B", "\x1b[B\x1b[1;1:2B\x1b[1;1:2B\x1b[1;1:3B" },
        .{ native.InputEvent{ .kind = 3, .code = 3, .physical = 52 }, "\x7f\x7f\x7f", "\x1b[127u\x1b[127;1:2u\x1b[127;1:2u\x1b[127;1:3u" },
        .{ native.InputEvent{ .kind = 4, .code = 'j', .mods = 4, .physical = 39 }, "\n\n\n", "\x1b[106;5u\x1b[106;5:2u\x1b[106;5:2u\x1b[106;5:3u" },
    };
    inline for (.{ @as(u8, 0), @as(u8, 10) }) |flags| {
        session.gui.app.model.workspace.findPane(Session.pane_id).?.input_modes.kitty_keyboard_flags = flags;
        inline for (fixtures) |fixture| {
            const before = session.input_len;
            var event = fixture[0];
            try input_support.acceptNative(session.gui, event);
            event.phase = 2;
            try input_support.acceptNative(session.gui, event);
            try input_support.acceptNative(session.gui, event);
            event.phase = 3;
            try input_support.acceptNative(session.gui, event);
            event.phase = 2;
            try input_support.acceptNative(session.gui, event);
            try drainInput(session);
            try std.testing.expectEqualStrings(if (flags == 0) fixture[1] else fixture[2], session.input[before..session.input_len]);
            try std.testing.expectEqual(@as(usize, 0), session.gui.router.leases.count());
        }
    }
}

test "native application repeat keeps its pane when focus changes" {
    const session = try Session.init();
    defer session.deinit();
    try session.bootstrap();
    try session.receiveFrame(1);
    const app = &session.gui.app;
    const model = app.model.activeTabModel().?;
    const second: core.PaneId = @enumFromInt(11);
    try model.split(.{ .existing_pane = Session.pane_id, .new_pane = second, .location = Session.location, .axis = .horizontal, .area = session.gui.region.area });
    _ = model.layout.focusPane(Session.pane_id);
    try input_support.acceptNative(session.gui, .{ .kind = 1, .text = "j".ptr, .len = 1, .physical = 39 });
    try drainInput(session);
    _ = model.layout.focusPane(second);
    try input_support.acceptNative(session.gui, .{ .kind = 1, .text = "j".ptr, .len = 1, .physical = 39, .phase = 2 });
    try input_support.pump(session.gui);
    const request = try core.decodeClient(session.pending.?);
    try std.testing.expectEqual(Session.pane_id, request.pane_input.pane_id);
    try std.testing.expectEqualStrings("j", request.pane_input.bytes);
    try session.settle();
    try input_support.acceptNative(session.gui, .{ .kind = 4, .code = 'j', .physical = 39, .phase = 3 });
    try drainInput(session);
    try std.testing.expectEqual(second, model.layout.focused().?);
}
