const pane_splits = @import("../panes/pane_splits.zig");
const std = @import("std");
const Axis = @import("../../workspace/layout_support.zig").Axis;
const pane_focus = @import("../panes/pane_focus.zig");
const pane_closures = @import("../panes/pane_closures.zig");
const Direction = @import("../../workspace/layout_support.zig").Direction;
const pane_geometry = @import("../panes/pane_geometry.zig");
const copy_modes = @import("../input/copy_modes.zig");
const pane_viewports = @import("../panes/pane_viewports.zig");
const agent_threads = @import("../agents/agent_threads.zig");
const core = @import("telar-core");
const Client = @import("../../AttachedClient.zig");
const runtime_transport = @import("../../entrypoints/runtime_io.zig");

/// Applies one routed command within this domain. Example: `try pane_commands.execute(client, reply);`
pub fn execute(client: *Client, reply: *core.ClientCommand) !void {
    switch (reply.action) {
        .pane_copy => {
            const selection = try core.CopySelection.fromText(@enumFromInt(reply.target_id), reply.text());
            const tab = client.model.activeTabModelConst() orelse return error.NoActiveTab;
            const pane = tab.findConst(selection.pane_id) orelse return error.PaneNotFound;
            if (!pane.attached or pane.kind != .terminal) {
                return error.TerminalPaneNotAttached;
            }

            try runtime_transport.enqueue(client, .{ .copy_selection = selection });
            reply.length = 0;
            reply.status = .admitted;
        },
        .pane_scroll => {
            const delta = std.math.cast(i32, reply.value) orelse return error.InvalidScrollDelta;
            const pane_id: core.PaneId = @enumFromInt(reply.target_id);
            const tab = client.model.activeTabModelConst() orelse return error.NoActiveTab;
            const pane = tab.findConst(pane_id) orelse return error.PaneNotFound;
            if (!pane.attached or copy_modes.active(client)) {
                return error.PaneViewportUnavailable;
            }

            if (pane.kind == .agent) {
                try agent_threads.scroll(client, pane_id, @floatFromInt(delta));
            } else {
                _ = try pane_viewports.apply(client, .{ .pane_id = pane_id, .target = .{ .relative = delta } });
            }

            reply.status = .applied;
        },
        .pane_fullscreen => {
            try focusPane(client, reply.target_id);
            const changed = try pane_geometry.toggleFullscreen(client, .{ .area = client.geometry().area }) orelse return error.PaneFullscreenUnavailable;
            reply.value = @intFromBool(changed.fullscreen);
            reply.status = .applied;
        },
        .pane_resize => {
            const direction = std.meta.stringToEnum(Direction, reply.text()) orelse return error.InvalidPaneDirection;
            try focusPane(client, reply.target_id);
            if (try pane_geometry.resize(client, .{ .direction = direction, .area = client.geometry().area }) == null) {
                return error.PaneResizeUnavailable;
            }

            reply.length = 0;
            reply.status = .applied;
        },
        .pane_focus => {
            try focusPane(client, reply.target_id);
            reply.status = .applied;
        },
        .pane_close => {
            try focusPane(client, reply.target_id);
            if (try pane_closures.request(
                client,
            ) == null) {
                return error.PaneClosureUnavailable;
            }

            reply.status = .admitted;
        },
        .pane_split => {
            const axis = std.meta.stringToEnum(Axis, reply.text()) orelse return error.InvalidSplitAxis;
            try focusPane(client, reply.target_id);
            if (try pane_splits.request(client, .{ .axis = axis, .area = client.geometry().area }) == null) {
                return error.PaneCreationUnavailable;
            }

            reply.length = 0;
            reply.status = .admitted;
        },
        .pane_create => {
            if (try pane_splits.request(client, .{ .axis = .horizontal, .area = client.geometry().area }) == null) {
                return error.PaneCreationUnavailable;
            }

            reply.status = .admitted;
        },
        else => return error.InvalidClientCommand,
    }
}

fn focusPane(client: *Client, target_id: u64) !void {
    if (target_id == 0) {
        return error.InvalidPaneId;
    }

    const pane_id: core.PaneId = @enumFromInt(target_id);
    const tab = client.model.activeTabModelConst() orelse return error.NoActiveTab;
    _ = tab.findConst(pane_id) orelse return error.PaneNotFound;
    if (tab.layout.focused() == pane_id) {
        return;
    }

    if (try pane_focus.apply(client, .{ .target = .{ .pane_id = pane_id }, .area = client.geometry().area }) == null) {
        return error.PaneFocusUnavailable;
    }
}
