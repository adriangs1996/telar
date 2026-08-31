//! Wires tab-close and tab-removal use cases to one client's protocol state.

const std = @import("std");
const core = @import("telar-core");
const workspace_capability = @import("../workspace/root.zig");
const client_application = @import("application/root.zig");
const client_model = @import("model.zig");
const pane_focus = @import("pane_focus.zig");
const pane_focus_reports = @import("pane_focus_reports.zig");
const pane_resources = @import("pane_resources.zig");
const request_lifecycle = @import("request_lifecycle.zig");
const tab_attachments = @import("tab_attachments.zig");
const workspace_handoffs = @import("workspace_handoffs.zig");

const Client = @import("client.zig");
const close_tab = client_application.close_tab;
const runtime_transport = @import("runtime_transport.zig");
const schema = core.schema;
const tabs_mod = workspace_capability.tabs;

pub const Outcome = enum {
    applied,
    ignored,
    exit,
};

/// Wires an interactive close to bounded delivery and provisional attachment
/// recovery.
///
/// ```zig
/// var handler = requestHandler(client);
/// if (!try handler.execute()) {
///     return;
/// }
/// ```
pub fn requestHandler(client: *Client) close_tab.RequestCloseTabHandler {
    return .{
        .model = &client.model,
        .gate = .{
            .context = client,
            .pending = tabOperationPending,
        },
        .effects = .{
            .context = client,
            .prepare = prepareClose,
            .detach = detachForClose,
            .send = sendClose,
            .restore = restoreClose,
        },
    };
}

/// Wires close-request rejection to canonical attachment recovery.
///
/// ```zig
/// var handler = recoveryHandler(client);
/// _ = try handler.execute(location);
/// ```
pub fn recoveryHandler(client: *Client) close_tab.RecoverCloseTabHandler {
    return .{
        .model = &client.model,
        .effects = .{
            .context = client,
            .restore = restoreClose,
        },
    };
}

/// Consumes one explicit response or applies one autonomous lifecycle removal.
///
/// ```zig
/// const outcome = try apply(client, closed);
/// ```
pub fn apply(client: *Client, closed: schema.TabClosed) !Outcome {
    const trigger: close_tab.RemovalTrigger = if (closed.request_id == .none)
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

    var use_case = removalHandler(client);
    const directive = try use_case.execute(.{
        .location = closed.location,
        .workspace_removed = closed.workspace_closed,
        .previous_workspace = closed.previous_workspace,
        .trigger = trigger,
    });

    return switch (directive) {
        .continue_running => .applied,
        .exit => .exit,
    };
}

fn removalHandler(client: *Client) close_tab.ApplyTabRemovalHandler {
    return .{
        .model = &client.model,
        .effects = .{
            .context = client,
            .retire_requests = retireRequests,
            .release_resources = releaseResources,
            .forget_workspace = forgetWorkspace,
            .request_workspace = requestWorkspace,
        },
    };
}

fn tabOperationPending(context: *anyopaque) bool {
    const client: *Client = @ptrCast(@alignCast(context));
    return request_lifecycle.has(client, .tab_operation);
}

fn prepareClose(context: *anyopaque, location: schema.TabLocation) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    const tab = findTab(&client.model.workspace, location) orelse return error.UnexpectedTabClosure;

    try request_lifecycle.ensureCanStart(client, 2);

    var required_capacity: usize = 1;
    if (client.model.panePasteSession()) |session| {
        const closes_session = tab.model.findConst(session.pane_id) != null and session.bracketed_paste;
        required_capacity += @intFromBool(closes_session);
    }

    if (client.model.reportedPaneFocus()) |reported| {
        if (tab.model.findConst(reported.pane_id)) |pane| {
            required_capacity += @intFromBool(reported.focus_events and pane.attached);
        }
    }

    var panes = tab.model.paneIterator();
    while (panes.next()) |pane| {
        const attachment_pending = request_lifecycle.hasPane(client, .attachment, pane.id);
        required_capacity += @intFromBool(pane.attached or attachment_pending);
    }

    const available_capacity = runtime_transport.availableCapacity(client);
    if (required_capacity > available_capacity) {
        return error.ClientOutboxFull;
    }
}

fn detachForClose(context: *anyopaque, location: schema.TabLocation) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    try tab_attachments.detach(client, location);
}

fn sendClose(context: *anyopaque, intent: close_tab.TabCloseIntent) !void {
    const client: *Client = @ptrCast(@alignCast(context));
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

fn restoreClose(context: *anyopaque, location: schema.TabLocation) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    if (request_lifecycle.has(client, .tab_snapshot)) {
        return;
    }

    try request_lifecycle.requestTabSnapshot(client, location);
}

fn retireRequests(context: *anyopaque, location: schema.TabLocation) void {
    const client: *Client = @ptrCast(@alignCast(context));
    request_lifecycle.ignoreTab(client, location.tab_id);
}

fn releaseResources(context: *anyopaque, removal_result: client_model.TabRemoval) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    for (removal_result.panes.slice()) |pane_id| {
        pane_resources.release(client, pane_id);
    }

    if (!removal_result.was_active) {
        return;
    }

    _ = pane_focus_reports.retire(client);
    const active_location = removal_result.active orelse return;
    const active = findTab(&client.model.workspace, active_location) orelse return error.UnexpectedTabRemoval;

    var panes = active.model.paneIterator();
    while (panes.next()) |pane| {
        try client.graphics_store.setPaneVisible(pane.id, true);
    }

    try pane_focus.syncResources(client);
    if (!request_lifecycle.has(client, .tab_snapshot)) {
        try request_lifecycle.requestTabSnapshot(client, active.location);
    }
}

fn forgetWorkspace(context: *anyopaque, workspace: schema.WorkspaceLocation) void {
    const client: *Client = @ptrCast(@alignCast(context));
    client.navigation_history.forget(workspace);
}

fn requestWorkspace(context: *anyopaque, workspace: schema.WorkspaceId) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    _ = try workspace_handoffs.followWorkspace(client, workspace);
}

fn findTab(workspace: *tabs_mod.Model, location: schema.TabLocation) ?*tabs_mod.Tab {
    const tab = workspace.find(location.tab_id) orelse return null;
    if (!std.meta.eql(tab.location, location)) {
        return null;
    }

    return tab;
}
