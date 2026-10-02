//! Test native admission through the same owner and notification path as the host.
const Session = @import("Session.zig");
const keyinput = @import("keyinput");
const native = @import("../native/native.zig");
const event_module = @import("../input/event.zig");
const data = @import("model");
const std = @import("std");
const GuiAdapter = @import("../GuiAdapter.zig");
const decode_input = @import("../native/decode_input.zig");

/// Example: `try input_support.acceptNative(gui, native_event);`
pub fn acceptNative(gui: *GuiAdapter, event: native.InputEvent) !void {
    try accept(gui, try decode_input.decode(event));
}

/// Example: `try input_support.accept(gui, .{ .paste = "text" });`
pub fn accept(gui: *GuiAdapter, event: event_module.Event) !void {
    if (!try gui.acceptInput(event)) {
        return error.InputRejected;
    }
}

/// Process queued input using the same readiness message and update as the host.
/// Example: `try input_support.pump(gui);`
pub fn pump(gui: *GuiAdapter) !void {
    try gui.resumeInput();
    _ = try gui.update();
}

/// Example: `try input_support.presented(gui, token, true,);`
pub fn presented(gui: *GuiAdapter, token: u64, delivered: bool) !void {
    try gui.driver.inbox.post(.{
        .presented = .{
            .token = token,
            .delivered = delivered,
        },
    });
    _ = try gui.update();
}

/// Example: `try input_support.focus(gui, false);`
pub fn focus(gui: *GuiAdapter, focused: bool) !void {
    try accept(gui, .{
        .focus = focused,
    });
    _ = try gui.update();
}

/// Example: `try input_support.bindingExpired(gui);`
pub fn bindingExpired(gui: *GuiAdapter) !void {
    try gui.driver.inbox.post(.{
        .binding_timeout = {},
    });
    _ = try gui.update();
}

/// Trigger a configured binding through host admission instead of invoking an
/// internal action directly. Example: `_ = try input_support.action(gui, .toggle_sidebar);`
pub fn action(gui: *GuiAdapter, value: data.actions.Action) !keyinput.Control {
    const binding = try data.config_values.ConfiguredBinding.parse(&.{"alt+z"}, value);
    gui.adoptBindings(.{
        .prefix = data.keybind.default_prefix,
        .bindings = &.{binding},
        .sequence_timeout_ns = std.time.ns_per_s,
    });
    try accept(gui, .{
        .key = .{
            .code = .{ .char = .init("z") },
            .mods = .{ .alt = true },
        },
    });
    return if (try gui.update() != null) .stop else .continue_routing;
}

/// Creates a sized terminal fixture for native widget interactions.
/// Example: `const fixture = try input_support.createSession();`
pub fn createSession() !*Session {
    const session = try Session.init();
    errdefer session.deinit();
    try session.bootstrap();
    const size = try session.gui.resizeViewport(
        .{
            .width = 1100,
            .height = 750,
            .scale = 1,
        },
    );
    try session.gui.resize(size, session.gui.renderer.theme);
    session.gui.pointer.configure(session.gui.renderer.origin, size);
    _ = session.gui.app.model.panes.find(Session.pane_id).?.identify(77);
    try session.settle();
    return session;
}
