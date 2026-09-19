const tab_selections = @import("../tabs/tab_selections.zig");
const pane_splits = @import("../panes/pane_splits.zig");
const std = @import("std");
const Axis = @import("../../workspace/layout_support.zig").Axis;
const pane_focus = @import("../panes/pane_focus.zig");
const pane_closures = @import("../panes/pane_closures.zig");
const core = @import("telar-core");
const Client = @import("../../AttachedClient.zig");
const runtime_transport = @import("../../entrypoints/runtime_io.zig");
const tab_creations = @import("../tabs/tab_creations.zig");
const workspace_handoffs = @import("../workspaces/workspace_handoffs.zig");

/// Executes a semantic command in this client's disposable state. Example: `try client_commands.apply(client, command);`
pub fn apply(client: *Client, command: core.ClientCommand) !void {
    var reply = command;
    execute(client, &reply) catch |err| {
        reply.status = .failed;
        try reply.setText(@errorName(err));
    };
    try runtime_transport.enqueueClientCompletion(client, reply);
}

fn execute(client: *Client, reply: *core.ClientCommand) !void {
    if (reply.status != .request) {
        return error.InvalidClientCommand;
    }

    switch (reply.action) {
        .pane_focus => {
            try focusPane(client, reply.target_id);
            reply.status = .applied;
        },
        .pane_close => {
            try focusPane(client, reply.target_id);
            var handler = pane_closures.requestHandler(client);
            if (try handler.execute() == null) {
                return error.PaneClosureUnavailable;
            }

            reply.status = .admitted;
        },
        .pane_split => {
            const axis = std.meta.stringToEnum(Axis, reply.text()) orelse return error.InvalidSplitAxis;
            try focusPane(client, reply.target_id);
            var handler = pane_splits.requestHandler(client);
            if (try handler.execute(.{ .axis = axis, .area = client.geometry().area }) == null) {
                return error.PaneCreationUnavailable;
            }

            reply.length = 0;
            reply.status = .admitted;
        },
        .pane_create => {
            var handler = pane_splits.requestHandler(client);
            if (try handler.execute(.{ .axis = .horizontal, .area = client.geometry().area }) == null) {
                return error.PaneCreationUnavailable;
            }

            reply.status = .admitted;
        },
        .tab_previous => {
            try selectTabOffset(client, reply, -1);
        },
        .tab_next => {
            try selectTabOffset(client, reply, 1);
        },
        .tab_select => {
            const target: core.TabId = @enumFromInt(reply.target_id);
            if (reply.target_id == 0 or client.model.tabLocation(target) == null) {
                return error.TabNotFound;
            }

            if (client.model.activeTabLocation()) |active| {
                if (active.tab_id == target) {
                    reply.status = .applied;
                    return;
                }
            }

            var handler = tab_selections.selectionHandler(client);
            if (try handler.execute(.{ .target = .{ .tab_id = target } }) == null) {
                return error.ClientBusy;
            }

            reply.status = .admitted;
        },
        .tab_create => {
            var handler = tab_creations.requestHandler(client);
            if (!try handler.execute(.{ .label = reply.text() })) {
                return error.ClientBusy;
            }

            reply.length = 0;
            reply.status = .admitted;
        },
        .workspace_select => {
            if (reply.target_id == 0) {
                return error.InvalidWorkspaceId;
            }

            const target: core.WorkspaceId = @enumFromInt(reply.target_id);
            if (!client.model.knowsWorkspace(target)) {
                return error.WorkspaceNotFound;
            }

            if (client.model.workspaceLocation()) |location| {
                if (location == .workspace and location.workspace == target) {
                    reply.status = .applied;
                    return;
                }
            }

            if (!try workspace_handoffs.selectWorkspace(client, .{ .workspace = target })) {
                return error.ClientBusy;
            }

            reply.status = .admitted;
        },
    }
}

fn selectTabOffset(client: *Client, reply: *core.ClientCommand, offset: isize) !void {
    if (client.model.activeTabLocation() == null) {
        return error.NoActiveTab;
    }

    var handler = tab_selections.selectionHandler(client);
    if (handler.snapshots.pending(handler.snapshots.context)) {
        return error.ClientBusy;
    }

    const change = try handler.execute(.{ .target = .{ .offset = offset } });
    reply.status = if (change == null) .applied else .admitted;
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

    var handler = pane_focus.handler(client);
    if (try handler.execute(.{ .target = .{ .pane_id = pane_id }, .area = client.geometry().area }) == null) {
        return error.PaneFocusUnavailable;
    }
}
