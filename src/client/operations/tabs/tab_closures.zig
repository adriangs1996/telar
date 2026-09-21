//! Wires tab-close and tab-removal use cases to one client's protocol state.

const Client = @import("../../AttachedClient.zig");
const TabClosedType = @import("telar-core").TabClosed;
const RemovalTriggerType = @import("../../application/tabs/close_tab.zig").RemovalTrigger;
const request_lifecycle = @import("../../connection/request_lifecycle.zig");
const std = @import("std");
const TabLocationType = @import("telar-core").TabLocation;
const tab_attachments = @import("tab_attachments.zig");
const TabCloseIntentType = @import("../../application/tabs/TabCloseIntent.zig");
const active_pane_resources = @import("../panes/active_pane_resources.zig");
const workspace_handoffs = @import("../workspaces/workspace_handoffs.zig");

const tab_snapshots = @import("tab_snapshots.zig");
const pane_resources = @import("../panes/pane_resources.zig");
const close_tab = @import("../../application/tabs/close_tab.zig");

const ApplyTabRemoval = @import("../../application/tabs/ApplyTabRemoval.zig");

pub const Outcome = enum { applied, ignored, exit };

/// Preflights all deliveries before detaching; failure requests canonical recovery. Example: `_ = try request(client);`
pub fn request(client: *Client) !bool {
    if (request_lifecycle.has(client, .tab_operation)) {
        return false;
    }

    const location = client.model.activeTabLocation() orelse return false;
    const plan = try client.model.planTabDetachment(location);
    try request_lifecycle.ensureCanStart(client, 2);
    if (1 + tab_attachments.requiredCapacity(client, &plan) > client.runtime_transport.outbox.availableCapacity()) {
        return error.ClientOutboxFull;
    }

    tab_attachments.detach(client, location) catch |err| {
        _ = try tab_snapshots.recover(client, location);
        return err;
    };
    send(client, .{ .location = location }) catch |err| {
        _ = try tab_snapshots.recover(client, location);
        return err;
    };

    return true;
}

/// Restores a rejected close only while its exact tab remains active. Example: `_ = try recover(client, location);`
pub fn recover(client: *Client, location: TabLocationType) !bool {
    const active = client.model.activeTabLocation() orelse return false;
    if (!std.meta.eql(active, location)) {
        return false;
    }

    _ = try tab_snapshots.recover(client, location);
    return true;
}

/// Commits correlated or autonomous runtime removal and follows its surviving workspace. Example: `_ = try apply(client, closed);`
pub fn apply(client: *Client, closed: TabClosedType) !Outcome {
    const trigger: RemovalTriggerType = if (closed.request_id == .none)
        .lifecycle
    else requested: {
        const continuation = request_lifecycle.consume(client, closed.request_id) orelse
            return error.UnexpectedTabClosed;
        const expected_location = switch (continuation) {
            .close_tab => |location| location,
            .ignored => return .ignored,
            else => return error.UnexpectedTabClosed,
        };
        if (!std.meta.eql(expected_location, closed.location)) {
            return error.UnexpectedTabClosed;
        }

        break :requested .requested;
    };

    const command: ApplyTabRemoval = .{
        .location = closed.location,
        .workspace_removed = closed.workspace_closed,
        .previous_workspace = closed.previous_workspace,
        .trigger = trigger,
    };
    try close_tab.validateWorkspaceTransition(command);
    const commit = try client.model.removeTab(.{ .location = command.location, .workspace_removed = command.workspace_removed });
    if (commit == .stale and command.trigger == .requested) {
        return switch (commit.stale.absence) {
            .workspace => error.UnexpectedWorkspace,
            .tab => error.UnexpectedTab,
        };
    }

    const removal = switch (commit) {
        .stale => |stale| {
            request_lifecycle.ignoreTab(client, stale.location.tab_id);
            return .applied;
        },
        .removed => |removed| removed,
    };
    request_lifecycle.ignoreTab(client, removal.removed.tab_id);
    for (removal.panes.slice()) |pane_id| {
        pane_resources.release(client, pane_id);
    }

    if (removal.was_active) {
        _ = client.model.forgetReportedPaneFocus();
        if (removal.active) |location| {
            const active = client.model.workspace.find(location.tab_id) orelse return error.StaleTabRemoval;
            var panes = active.model.paneIterator();
            while (panes.next()) |pane| {
                try client.graphics.setPaneVisible(pane.id, true);
            }

            try active_pane_resources.synchronize(client);
            _ = try tab_snapshots.recover(client, location);
        }
    }

    if (!removal.workspace_removed) {
        return .applied;
    }

    client.navigation_history.forget(removal.removed.workspace);
    const previous = command.previous_workspace orelse return .exit;
    _ = try workspace_handoffs.followWorkspace(client, previous);
    return .applied;
}

fn send(client: *Client, intent: TabCloseIntentType) !void {
    const request_id = try request_lifecycle.nextId(client);

    try request_lifecycle.deliver(client, .{
        .registration = .{
            .request_id = request_id,
            .continuation = .{ .close_tab = intent.location },
        },
        .message = .{ .close_tab = .{
            .request_id = request_id,
            .location = intent.location,
        } },
    });
}
