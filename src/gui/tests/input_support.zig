//! Test native admission through the same owner and notification path as the host.
const std = @import("std");
const client = @import("telar-client");
const GuiClient = @import("../GuiClient.zig");
const NativeEvent = @import("../native/native.zig").InputEvent;
const Event = @import("../input/event.zig").Event;
const decode_input = @import("../native/decode_input.zig");

/// Example: `try input_support.acceptNative(gui, native_event);`
pub fn acceptNative(gui: *GuiClient, event: NativeEvent) !void {
    try accept(gui, try decode_input.decode(event));
}

/// Example: `try input_support.accept(gui, .{ .paste = "text" });`
pub fn accept(gui: *GuiClient, event: Event) !void {
    if (!try gui.acceptInput(event)) {
        return error.InputRejected;
    }
}

/// Process queued input using the same readiness message and update as the host.
/// Example: `try input_support.pump(gui);`
pub fn pump(gui: *GuiClient) !void {
    try gui.resumeInput();
    _ = try gui.update();
}

/// Example: `try input_support.presented(gui, token, true,);`
pub fn presented(gui: *GuiClient, token: u64, delivered: bool) !void {
    try gui.driver.inbox.post(.{
        .presented = .{
            .token = token,
            .delivered = delivered,
        },
    });
    _ = try gui.update();
}

/// Example: `try input_support.focus(gui, false);`
pub fn focus(gui: *GuiClient, focused: bool) !void {
    try accept(gui, .{
        .focus = focused,
    });
    _ = try gui.update();
}

/// Example: `try input_support.bindingExpired(gui);`
pub fn bindingExpired(gui: *GuiClient) !void {
    try gui.driver.inbox.post(.{
        .binding_timeout = {},
    });
    _ = try gui.update();
}

/// Trigger a configured binding through host admission instead of invoking an
/// internal action directly. Example: `_ = try input_support.action(gui, .toggle_sidebar);`
pub fn action(gui: *GuiClient, value: client.Action) !client.Control {
    const binding = try client.config_model.ConfiguredBinding.parse(&.{"alt+z"}, value);
    gui.adoptBindings(.{
        .prefix = client.default_prefix,
        .bindings = &.{binding},
        .escape_timeout_ns = std.time.ns_per_s,
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
