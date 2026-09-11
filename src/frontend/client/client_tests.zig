//! Disposable multi-pane client for Telar's current schema.
//!
//! This file is the capability's public namespace (ADR-0002); the files in
//! this directory are implementation details behind it.

const Client = @import("Client.zig");
const events = @import("entrypoints/events.zig");
const runtime_messages = @import("entrypoints/runtime_messages.zig");
const run = @import("run.zig");
const std = @import("std");
const Action = @import("telar-client").Action;
const parseKey_module = @import("telar-client").parseKey;
const default_bindings = @import("../config/default_bindings.zig");
const DirectionType = @import("telar-client").Direction;
const host_inputs = @import("controllers/input/host_inputs.zig");
const encodeSgr_module = @import("telar-client").encodeSgr;
const tracked_module = @import("telar-client").tracked;

test {
    // The client capability's own files, collected for the suite.
    _ = @import("telar-client");
    _ = Client;
    _ = @import("connection/request_lifecycle.zig");
    _ = @import("controllers/agents/agent_navigation.zig");
    _ = @import("controllers/agents/agent_snapshots.zig");
    _ = @import("controllers/agents/agent_sounds.zig");
    _ = @import("controllers/agents/proxy_status.zig");
    _ = @import("controllers/agents/system_metrics.zig");
    _ = @import("controllers/configuration/bar_updates.zig");
    _ = @import("controllers/configuration/config_reloads.zig");
    _ = @import("controllers/configuration/lua_actions.zig");
    _ = @import("controllers/configuration/plugin_actions.zig");
    _ = @import("controllers/host/clipboard_images.zig");
    _ = @import("controllers/host/host_capabilities.zig");
    _ = @import("controllers/host/host_resizes.zig");
    _ = @import("controllers/host/host_resources.zig");
    _ = @import("controllers/input/action_routing.zig");
    _ = @import("controllers/input/actions.zig");
    _ = @import("controllers/input/attachment_prompts.zig");
    _ = @import("controllers/input/copy_mode_pointer.zig");
    _ = @import("controllers/input/copy_modes.zig");
    _ = @import("controllers/input/host_inputs.zig");
    _ = @import("controllers/input/key_routing.zig");
    _ = @import("controllers/input/link_openings.zig");
    _ = @import("controllers/input/name_prompts.zig");
    _ = @import("controllers/input/pane_inputs.zig");
    _ = @import("controllers/input/pane_mouse_inputs.zig");
    _ = @import("controllers/input/pane_pastes.zig");
    _ = @import("controllers/input/paste_routing.zig");
    _ = @import("controllers/input/pointer_routing.zig");
    _ = @import("controllers/input/view_interactions.zig");
    _ = @import("controllers/notifications/notifications.zig");
    _ = @import("controllers/notifications/sidebar_animations.zig");
    _ = @import("controllers/notifications/sidebar_projection.zig");
    _ = @import("controllers/notifications/sidebar_toggles.zig");
    _ = @import("controllers/panes/active_pane_resources.zig");
    _ = @import("controllers/panes/pane_attachments.zig");
    _ = @import("controllers/panes/pane_clipboards.zig");
    _ = @import("controllers/panes/pane_closures.zig");
    _ = @import("controllers/panes/pane_focus.zig");
    _ = @import("controllers/panes/pane_focus_commands.zig");
    _ = @import("controllers/panes/pane_focus_reports.zig");
    _ = @import("controllers/panes/pane_frames.zig");
    _ = @import("controllers/panes/pane_geometry.zig");
    _ = @import("controllers/panes/pane_graphics.zig");
    _ = @import("controllers/panes/pane_metadata.zig");
    _ = @import("controllers/panes/pane_openings.zig");
    _ = @import("controllers/panes/pane_progress.zig");
    _ = @import("controllers/panes/pane_resources.zig");
    _ = @import("controllers/panes/pane_splits.zig");
    _ = @import("controllers/panes/pane_viewports.zig");
    _ = @import("controllers/session/client_detachments.zig");
    _ = @import("controllers/session/client_layouts.zig");
    _ = @import("controllers/session/client_startup.zig");
    _ = @import("controllers/session/request_failures.zig");
    _ = @import("controllers/session/resync_requirements.zig");
    _ = @import("controllers/tabs/tab_attachments.zig");
    _ = @import("controllers/tabs/tab_closures.zig");
    _ = @import("controllers/tabs/tab_creations.zig");
    _ = @import("controllers/tabs/tab_moves.zig");
    _ = @import("controllers/tabs/tab_renames.zig");
    _ = @import("controllers/tabs/tab_selections.zig");
    _ = @import("controllers/tabs/tab_snapshots.zig");
    _ = @import("controllers/workspaces/workspace_creations.zig");
    _ = @import("controllers/workspaces/workspace_handoffs.zig");
    _ = @import("controllers/workspaces/workspace_lists.zig");
    _ = @import("controllers/workspaces/workspace_renames.zig");
    _ = @import("controllers/workspaces/workspace_snapshots.zig");
    _ = @import("controllers/workspaces/workspace_transitions.zig");
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
    _ = @import("telar-client");
    _ = @import("telar-client");
    _ = @import("telar-client");
    _ = @import("presentation/Presenter.zig");
    _ = @import("presentation/history_inspection.zig");
    _ = @import("presentation/presentation_lifecycle.zig");
    _ = @import("presentation/presentation_projection.zig");
    _ = @import("presentation/view.zig");
    _ = @import("resources/InputHandler.zig");
    _ = @import("resources/client_layouts.zig");
    _ = @import("resources/config_reload.zig");
    _ = @import("resources/host_output.zig");
    _ = @import("resources/notification_timers.zig");
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
