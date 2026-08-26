//! Disposable multi-pane client for Telar's current schema.
//!
//! This file is the capability's public namespace (ADR-0002); the files in
//! this directory are implementation details behind it.

const std = @import("std");
const input_capability = @import("../input/root.zig");
const client_outbox = @import("outbox.zig");
const client_view = @import("view.zig");
const lua_config = @import("../config/root.zig");
const action_mod = input_capability.action;
const keybind = input_capability.keybind;
const mouse_protocol = input_capability.mouse_protocol;

pub const Client = @import("client.zig");
pub const run = @import("run.zig").run;

pub const Action = action_mod.Action;
pub const Options = Client.Options;
pub const Outbox = client_outbox.Outbox;
pub const View = client_view.State;
pub const sidebar_width = client_view.sidebar_width;
pub const ConfiguredBinding = lua_config.ConfiguredBinding;
pub const trustWatchFingerprint = @import("config_reload.zig").trustWatchFingerprint;

const InputRouter = Client.InputRouter;
const defaultBindings = lua_config.loadDefaultBindings;
const encodeSgrMouse = mouse_protocol.encodeSgr;
const mouseTracked = mouse_protocol.tracked;

test {
    // The client capability's own files, collected for the suite.
    _ = @import("client.zig");
    _ = @import("client_test.zig");
    _ = @import("config_reload.zig");
    _ = @import("presenter.zig");
    _ = @import("server_messages.zig");
    _ = @import("input_handler.zig");
    _ = @import("run.zig");
    _ = @import("telemetry.zig");
    _ = @import("view.zig");
    _ = @import("requests.zig");
}

test "configured action names cover multiplexer operations" {
    try std.testing.expectEqualDeep(Action.detach, try Action.parse("detach"));
    try std.testing.expectEqualDeep(
        Action{ .split_pane = .horizontal },
        try Action.parse("split-horizontal"),
    );
    try std.testing.expectEqualDeep(Action.close_pane, try Action.parse("close-pane"));
    try std.testing.expectEqualDeep(
        Action{ .resize_pane = .left },
        try Action.parse("resize-left"),
    );
    try std.testing.expectEqualDeep(
        Action.toggle_pane_fullscreen,
        try Action.parse("toggle-pane-fullscreen"),
    );
    try std.testing.expectEqualDeep(Action.toggle_sidebar, try Action.parse("toggle-sidebar"));
    try std.testing.expectError(error.UnknownAction, Action.parse("rename-pane"));
}

test "default bindings compile without ambiguous prefixes" {
    const prefix = try keybind.parseKey("ctrl+s");
    var bindings = try defaultBindings(prefix);
    var resize_directions: std.EnumSet(action_mod.Direction) = .initEmpty();
    var fullscreen = false;
    for (bindings) |binding| {
        try std.testing.expectEqualDeep(prefix, binding.keys[0]);
        switch (binding.action) {
            .resize_pane => |direction| resize_directions.insert(direction),
            .toggle_pane_fullscreen => fullscreen = true,
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 4), resize_directions.count());
    try std.testing.expect(fullscreen);
    _ = try InputRouter.init(&bindings);
}

test "pane mouse reports preserve SGR buttons and pane-relative coordinates" {
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings(
        "\x1b[<0;3;5M",
        try encodeSgrMouse(&buffer, .{ .x = 20, .y = 30, .kind = .press, .button = 0 }, 2, 4, false, 0, 0, null, null),
    );
    try std.testing.expectEqualStrings(
        "\x1b[<0;3;5m",
        try encodeSgrMouse(&buffer, .{ .x = 20, .y = 30, .kind = .release, .button = 0 }, 2, 4, false, 0, 0, null, null),
    );
    try std.testing.expectEqualStrings(
        "\x1b[<0;26;91M",
        try encodeSgrMouse(&buffer, .{ .x = 20, .y = 30, .kind = .press, .button = 0 }, 2, 4, true, 10, 20, null, null),
    );
    try std.testing.expectEqualStrings(
        "\x1b[<0;8;10M",
        try encodeSgrMouse(&buffer, .{ .x = 20, .y = 30, .kind = .press, .button = 0 }, 2, 4, true, 10, 20, 7, 9),
    );
    try std.testing.expect(mouseTracked(.any, .move));
    try std.testing.expect(!mouseTracked(.button, .move));
    try std.testing.expect(mouseTracked(.x10, .press));
    try std.testing.expect(!mouseTracked(.x10, .release));
}
