const tab_selections = @import("../tabs/tab_selections.zig");
const core = @import("telar-core");
const Client = @import("../../AttachedClient.zig");
const tab_creations = @import("../tabs/tab_creations.zig");
const workspace_handoffs = @import("../workspaces/workspace_handoffs.zig");

/// Applies one routed command within this domain. Example: `try navigation_commands.execute(client, reply);`
pub fn execute(client: *Client, reply: *core.ClientCommand) !void {
    switch (reply.action) {
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

            if (try tab_selections.select(client, .{ .target = .{ .tab_id = target } }) == null) {
                return error.ClientBusy;
            }

            reply.status = .admitted;
        },
        .tab_create => {
            if (!try tab_creations.request(client, .{ .label = reply.text() })) {
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
        else => return error.InvalidClientCommand,
    }
}

fn selectTabOffset(client: *Client, reply: *core.ClientCommand, offset: isize) !void {
    if (client.model.activeTabLocation() == null) {
        return error.NoActiveTab;
    }

    if (client.request_lifecycle.tracker.has(.tab_snapshot)) {
        return error.ClientBusy;
    }

    const change = try tab_selections.select(client, .{ .target = .{ .offset = offset } });
    reply.status = if (change == null) .applied else .admitted;
}
