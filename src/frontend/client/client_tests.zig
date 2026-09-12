//! Disposable multi-pane client for Telar's current schema.
//!
//! This file is the capability's public namespace (ADR-0002); the files in
//! this directory are implementation details behind it.

const Client = @import("telar-client").AttachedClient;
const events = @import("entrypoints/events.zig");
const runtime_messages = @import("telar-client").server_messages;
const run = @import("run.zig");
const std = @import("std");
const Action = @import("telar-client").Action;
const parseKey_module = @import("telar-client").parseKey;
const default_bindings = @import("telar-client").default_bindings;
const DirectionType = @import("telar-client").Direction;
const host_inputs = @import("controllers/input/host_inputs.zig");
const encodeSgr_module = @import("telar-client").encodeSgr;
const tracked_module = @import("telar-client").tracked;

test {
    // The client capability's own files, collected for the suite.
    _ = Client;
    _ = @import("controllers/host/host_capabilities.zig");
    _ = @import("controllers/host/host_resizes.zig");
    _ = @import("controllers/input/host_inputs.zig");
    _ = @import("controllers/session/client_startup.zig");
    _ = events;
    _ = @import("tests/configuration.zig");
    _ = @import("tests/graphics_and_clipboard.zig");
    _ = @import("tests/history_browser.zig");
    _ = @import("tests/host_interaction.zig");
    _ = @import("tests/input.zig");
    _ = @import("tests/mouse_selection.zig");
    _ = @import("tests/notifications_and_agents.zig");
    _ = @import("tests/pane_lifecycle.zig");
    _ = @import("tests/pane_updates.zig");
    _ = @import("tests/presentation.zig");
    _ = @import("tests/renaming_and_telemetry.zig");
    _ = @import("tests/synchronization.zig");
    _ = @import("tests/tab_lifecycle.zig");
    _ = @import("tests/transport.zig");
    _ = @import("tests/workspace_lifecycle.zig");
    _ = runtime_messages;
    _ = @import("presentation/Presenter.zig");
    _ = @import("presentation/history_inspection.zig");
    _ = @import("presentation/presentation_lifecycle.zig");
    _ = @import("presentation/presentation_projection.zig");
    _ = @import("presentation/view.zig");
    _ = @import("resources/InputHandler.zig");
    _ = @import("resources/host_output.zig");
    _ = @import("resources/telemetry.zig");
    _ = run;
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
    const prefix = try parseKey_module("ctrl+s");
    var bindings = try default_bindings.load(prefix);
    var resize_directions: std.EnumSet(DirectionType) = .initEmpty();
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
    _ = try host_inputs.Router.init(&bindings);
}

test "pane mouse reports preserve SGR buttons and pane-relative coordinates" {
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings(
        "\x1b[<0;3;5M",
        try encodeSgr_module(&buffer, .{
            .event = .{ .x = 20, .y = 30, .kind = .press, .button = 0 },
            .pane_position = .{ .x = 2, .y = 4 },
        }),
    );
    try std.testing.expectEqualStrings(
        "\x1b[<0;3;5m",
        try encodeSgr_module(&buffer, .{
            .event = .{ .x = 20, .y = 30, .kind = .release, .button = 0 },
            .pane_position = .{ .x = 2, .y = 4 },
        }),
    );
    try std.testing.expectEqualStrings(
        "\x1b[<0;26;91M",
        try encodeSgr_module(&buffer, .{
            .event = .{ .x = 20, .y = 30, .kind = .press, .button = 0 },
            .pane_position = .{ .x = 2, .y = 4 },
            .pixels = .{ .cell = .{ .width = 10, .height = 20 } },
        }),
    );
    try std.testing.expectEqualStrings(
        "\x1b[<0;8;10M",
        try encodeSgr_module(&buffer, .{
            .event = .{ .x = 20, .y = 30, .kind = .press, .button = 0 },
            .pane_position = .{ .x = 2, .y = 4 },
            .pixels = .{
                .cell = .{ .width = 10, .height = 20 },
                .exact = .{ .x = 7, .y = 9 },
            },
        }),
    );
    try std.testing.expect(tracked_module(.any, .move));
    try std.testing.expect(!tracked_module(.button, .move));
    try std.testing.expect(tracked_module(.x10, .press));
    try std.testing.expect(!tracked_module(.x10, .release));
}
