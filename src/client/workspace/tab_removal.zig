//! Tab removal: detaches and closes tabs, releasing their panes.
const data = @import("model");
const core = @import("telar-core");
const std = @import("std");
const runtime_io = @import("../connection/runtime_io.zig");
const pane_closure = @import("../panes/pane_closure.zig");
const pane_focus = @import("../panes/pane_focus.zig");
const pane_input = @import("../panes/pane_input.zig");
const tab_snapshot = @import("tab_snapshot.zig");
const workspace_handoff = @import("workspace_handoff.zig");
const Client = @import("../execution/Client.zig");

const TabCloseOutcome = enum { applied, ignored, exit };

/// Finishes paste and focus, detaches in pane order, then commits detachment.
/// A failure preserves completed effects; the caller chooses recovery or exit.
/// Example: `try tab_removal.detachTab(app, location);`
pub fn detachTab(client: *Client, location: core.TabLocation) !void {
    const plan = try client.model.planTabDetachment(location);
    if (plan.owns_paste) {
        const outcome = try pane_input.finishPanePaste(client);
        std.debug.assert(outcome != .ignored);
    }

    if (plan.owns_reported_focus) {
        const outcome = try pane_focus.clearReportedFocus(&client.model);
        std.debug.assert(outcome == .applied);
    }

    for (plan.slice()) |pane| {
        const pending = client.model.request_lifecycle.tracker.hasPane(.attachment, pane.pane_id);
        if (!pane.attached and !pending) {
            continue;
        }

        try client.model.to_runtime.push(
            .{
                .detach_pane = .{
                    .pane_id = pane.pane_id,
                },
            },
        );
        _ = client.model.request_lifecycle.tracker.ignoreAttachment(pane.pane_id);
        try client.graphics.setPaneVisible(pane.pane_id, false);
    }

    try client.model.commitTabDetachment(plan);
}

/// Counts the deliveries needed to detach one tab, including pending attachments.
/// Example: `const required = try tab_removal.tabDetachmentCapacity(app, location);`
pub fn tabDetachmentCapacity(model: *const data.ClientModel, location: core.TabLocation) !usize {
    const plan = try model.planTabDetachment(location);
    var required = @as(usize, @intFromBool(plan.paste_marker_required));
    required += @intFromBool(plan.focus_out_required);
    for (plan.slice()) |pane| {
        required += @intFromBool(pane.attached or model.request_lifecycle.tracker.hasPane(.attachment, pane.pane_id));
    }

    return required;
}

pub fn requestTabClose(client: *Client) !bool {
    if (client.model.request_lifecycle.tracker.has(.tab_operation)) {
        return false;
    }

    const location = client.model.activeTabLocation() orelse return false;
    const required = try tabDetachmentCapacity(&client.model, location);
    try client.model.request_lifecycle.ensureCanStart(2);
    if (1 + required > client.model.to_runtime.availableCapacity()) {
        return error.ClientOutboxFull;
    }

    detachTab(client, location) catch |err| {
        _ = try tab_snapshot.recoverTabSnapshot(&client.model, location);
        return err;
    };

    sendTabClose(
        &client.model,
        .{
            .location = location,
        },
    ) catch |err| {
        _ = try tab_snapshot.recoverTabSnapshot(&client.model, location);
        return err;
    };

    return true;
}

pub fn recoverTabClose(model: *data.ClientModel, location: core.TabLocation) !bool {
    const active = model.activeTabLocation() orelse return false;
    if (!std.meta.eql(active, location)) {
        return false;
    }

    _ = try tab_snapshot.recoverTabSnapshot(model, location);
    return true;
}

pub fn completeTabClose(client: *Client, closed: core.TabClosed) !TabCloseOutcome {
    const trigger: data.TabCloseRemovalTrigger = if (closed.request_id == .none)
        .lifecycle
    else requested: {
        const continuation = client.model.request_lifecycle.tracker.take(closed.request_id) orelse
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

    const command: data.ApplyTabRemoval = .{
        .location = closed.location,
        .workspace_removed = closed.workspace_closed,
        .previous_workspace = closed.previous_workspace,
        .trigger = trigger,
    };

    try data.tab_close.validateWorkspaceTransition(command);
    const commit = try data.tab_removal.commitRemoval(&client.model, 
        .{
            .location = command.location,
            .workspace_removed = command.workspace_removed,
        },
    );
    if (commit == .stale and command.trigger == .requested) {
        return switch (commit.stale.absence) {
            .workspace => error.UnexpectedWorkspace,
            .tab => error.UnexpectedTab,
        };
    }

    const removal = switch (commit) {
        .stale => |stale| {
            client.model.request_lifecycle.tracker.ignoreTab(stale.location.tab_id);
            return .applied;
        },
        .removed => |removed| removed,
    };

    client.model.request_lifecycle.tracker.ignoreTab(removal.removed.tab_id);
    for (removal.panes.slice()) |pane_id| {
        pane_closure.releasePaneResources(client, pane_id);
    }

    if (removal.was_active) {
        _ = client.model.forgetReportedPaneFocus();
        if (removal.active) |location| {
            const active = client.model.tabs.find(location.tab_id) orelse return error.StaleTabRemoval;
            var panes = client.model.panes.iterate(client.model.tabs.location[active].tab_id);
            while (panes.next()) |pane| {
                try client.graphics.setPaneVisible(pane.id, true);
            }

            try pane_focus.synchronizeActivePane(client);
            _ = try tab_snapshot.recoverTabSnapshot(&client.model, location);
        }
    }

    if (!removal.workspace_removed) {
        return .applied;
    }

    client.model.navigation_history.forget(removal.removed.workspace);
    const previous = command.previous_workspace orelse return .exit;
    _ = try workspace_handoff.requestWorkspaceSwitch(
        client,
        .{
            .workspace = previous,
        },
        .canonical_follow,
    );
    return .applied;
}

fn sendTabClose(model: *data.ClientModel, intent: data.TabCloseIntent) !void {
    const request_id = try model.request_lifecycle.nextId();

    try runtime_io.sendRuntimeRequest(
        model,
        .{
            .registration = .{
                .request_id = request_id,
                .continuation = .{
                    .close_tab = intent.location,
                },
            },
            .message = .{
                .close_tab = .{
                    .request_id = request_id,
                    .location = intent.location,
                },
            },
        },
    );
}

/// Detaches every tab in stable client order before the event loop exits.
pub fn detachAllTabs(client: *Client) !void {
    var locations: [core.max_tabs_per_workspace]core.TabLocation = undefined;
    var count: usize = 0;
    for (client.model.tabs.location[0..client.model.tabs.count]) |location| {
        std.debug.assert(count < locations.len);
        locations[count] = location;
        count += 1;
    }

    for (locations[0..count]) |location| {
        try detachTab(client, location);
    }
}
