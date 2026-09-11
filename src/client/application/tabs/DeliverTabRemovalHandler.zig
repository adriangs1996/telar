const DeliverTabRemovalHandler = @This();
const client_model = @import("../../root.zig").model;
const Effects = @import("TabRemovalDeliveryEffects.zig");
const source_namespace = @import("tab_removal_delivery.zig");
const close_tab = @import("close_tab.zig");
const pane_resource_release = @import("../panes/root.zig").pane_resource_release;
const pane_focus_reporting = @import("../panes/root.zig").pane_focus_reporting;
const std = @import("std");
model: *client_model.Model,
effects: Effects,

/// Validates one exact removed or stale commit before retiring resources,
/// activating a successor tab and choosing workspace handoff or exit.
///
/// ```zig
/// const directive = try handler.execute(commit, previous_workspace);
/// ```
pub fn execute(handler: *DeliverTabRemovalHandler, commit: client_model.TabRemovalCommit, previous_workspace: ?source_namespace.schema.WorkspaceId) !close_tab.TabRemovalDirective {
    try handler.validate(commit);

    const removal = switch (commit) {
        .stale => |stale| {
            handler.effects.retire_tab_requests(handler.effects.context, stale.location);
            return .continue_running;
        },
        .removed => |removed| removed,
    };
    handler.effects.retire_tab_requests(handler.effects.context, removal.removed);

    var release_pane: pane_resource_release.ReleasePaneResourcesHandler = .{
        .model = handler.model,
        .effects = .{
            .context = handler.effects.context,
            .clear_graphics = handler.effects.clear_pane_graphics,
        },
    };
    for (removal.panes.slice()) |pane_id| {
        _ = release_pane.execute(pane_id);
    }

    if (removal.was_active) {
        var retire_focus: pane_focus_reporting.RetireReportedPaneFocusHandler = .{
            .model = handler.model,
        };
        _ = retire_focus.execute();

        if (removal.active) |active_location| {
            const active = try handler.exactTab(active_location);
            var panes = active.model.paneIterator();
            while (panes.next()) |pane| {
                try handler.effects.set_pane_graphics_visible(handler.effects.context, pane.id, true);
            }

            try handler.effects.synchronize_active_resources(handler.effects.context);
            if (!handler.effects.tab_snapshot_pending(handler.effects.context)) {
                try handler.effects.request_tab_snapshot(handler.effects.context, active_location);
            }
        }
    }

    if (!removal.workspace_removed) {
        return .continue_running;
    }

    handler.effects.forget_workspace(handler.effects.context, removal.removed.workspace);
    const previous = previous_workspace orelse return .exit;
    try handler.effects.request_workspace(handler.effects.context, previous);

    return .continue_running;
}

fn validate(handler: *const DeliverTabRemovalHandler, commit: client_model.TabRemovalCommit) !void {
    const version = handler.model.version();
    switch (commit) {
        .stale => |stale| {
            if (version.workspace != stale.workspace_revision or
                version.tabs != stale.tabs_revision or
                version.active_tab != stale.active_tab_revision or
                version.panes != stale.panes_revision or
                version.copy != stale.copy_revision)
            {
                return error.StaleTabRemoval;
            }

            const workspace = handler.model.workspace.workspace;
            switch (stale.absence) {
                .workspace => if (workspace != null and std.meta.eql(workspace.?, stale.location.workspace)) {
                    return error.StaleTabRemoval;
                },
                .tab => {
                    if (workspace == null or !std.meta.eql(workspace.?, stale.location.workspace)) {
                        return error.StaleTabRemoval;
                    }
                    if (handler.model.workspace.find(stale.location.tab_id) != null) {
                        return error.StaleTabRemoval;
                    }
                },
            }
        },
        .removed => |removal| {
            if (version.workspace != removal.workspace_revision or
                version.tabs != removal.tabs_revision or
                version.active_tab != removal.active_tab_revision or
                version.panes != removal.panes_revision or
                version.copy != removal.copy_revision or
                removal.active_tab_revision_before +% @intFromBool(removal.was_active) != removal.active_tab_revision or
                handler.model.workspace.find(removal.removed.tab_id) != null)
            {
                return error.StaleTabRemoval;
            }

            for (removal.panes.slice()) |pane_id| {
                if (handler.model.workspace.tabForPaneConst(pane_id) != null) {
                    return error.StaleTabRemoval;
                }
            }

            if (removal.workspace_removed) {
                if (!removal.was_active or removal.active != null or
                    removal.active_layout_revision != 0 or
                    handler.model.workspace.workspace != null)
                {
                    return error.StaleTabRemoval;
                }
                return;
            }

            const workspace = handler.model.workspace.workspace orelse return error.StaleTabRemoval;
            const active_location = removal.active orelse return error.StaleTabRemoval;
            const current_active = handler.model.activeTabLocation() orelse return error.StaleTabRemoval;
            if (!std.meta.eql(workspace, removal.removed.workspace) or
                std.meta.eql(active_location, removal.removed) or
                !std.meta.eql(current_active, active_location))
            {
                return error.StaleTabRemoval;
            }

            const active = try handler.exactTab(active_location);
            if (active.model.layout.currentRevision() != removal.active_layout_revision) {
                return error.StaleTabRemoval;
            }
        },
    }
}

fn exactTab(handler: *const DeliverTabRemovalHandler, location: source_namespace.schema.TabLocation) !*source_namespace.tabs_mod.Tab {
    const tab = handler.model.workspace.find(location.tab_id) orelse return error.StaleTabRemoval;
    if (!std.meta.eql(tab.location, location)) {
        return error.StaleTabRemoval;
    }

    return tab;
}
