const tab_selections = @import("../tabs/tab_selections.zig");
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
