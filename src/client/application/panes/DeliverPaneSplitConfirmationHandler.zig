const DeliverPaneSplitConfirmationHandler = @This();
const client_model = @import("../../root.zig").model;
const pane_geometry_delivery = @import("pane_geometry_delivery.zig");
const Effects = @import("PaneSplitConfirmationDeliveryEffects.zig");
const std = @import("std");
const source_namespace = @import("pane_split_confirmation_delivery.zig");
model: *client_model.Model,
geometry_effects: pane_geometry_delivery.OfferEffects,
effects: Effects,

/// Validates one exact split commit before applying the resource policy
/// selected by its active, inactive or stale disposition.
///
/// ```zig
/// try handler.execute(commit);
/// ```
pub fn execute(handler: *DeliverPaneSplitConfirmationHandler, commit: client_model.PaneSplitCommit) !void {
    try handler.validate(commit);

    switch (commit.disposition) {
        .active => {
            const tab = try handler.exactTab(commit.location);
            var offer_geometry: pane_geometry_delivery.OfferPaneGeometryHandler = .{
                .effects = handler.geometry_effects,
            };
            _ = try offer_geometry.execute(&tab.model, commit.area);
            try handler.effects.synchronize_active_resources(handler.effects.context);
        },
        .inactive => {
            try handler.effects.detach_pane(handler.effects.context, commit.pane_id);
            try handler.effects.set_pane_graphics_visible(handler.effects.context, commit.pane_id, false);
        },
        .stale => {
            try handler.effects.detach_pane(handler.effects.context, commit.pane_id);
            const workspace = handler.model.workspace.workspace orelse return;
            if (!std.meta.eql(workspace, commit.location.workspace)) {
                return;
            }
            if (handler.effects.workspace_snapshot_pending(handler.effects.context)) {
                return;
            }

            try handler.effects.request_workspace_snapshot(handler.effects.context, workspace);
        },
    }
}

fn validate(handler: *const DeliverPaneSplitConfirmationHandler, commit: client_model.PaneSplitCommit) !void {
    const version = handler.model.version();
    if (version.workspace != commit.workspace_revision or
        version.tabs != commit.tabs_revision or
        version.active_tab != commit.active_tab_revision or
        version.panes != commit.panes_revision)
    {
        return error.StalePaneSplitConfirmation;
    }

    switch (commit.disposition) {
        .active, .inactive => {
            const tab = try handler.exactTab(commit.location);
            const pane = tab.model.find(commit.pane_id) orelse return error.StalePaneSplitConfirmation;
            const active = handler.model.workspace.activeConst();
            const tab_active = active != null and std.meta.eql(active.?.location, commit.location);
            if (tab_active != (commit.disposition == .active) or
                pane.attached != tab_active or
                !std.meta.eql(pane.location, commit.location) or
                tab.model.layout.currentRevision() != commit.layout_revision or
                (commit.disposition == .inactive and commit.change != .unchanged))
            {
                return error.StalePaneSplitConfirmation;
            }
        },
        .stale => {
            if (commit.change != .unchanged or
                commit.layout_revision != 0 or
                handler.model.workspace.findPane(commit.pane_id) != null)
            {
                return error.StalePaneSplitConfirmation;
            }

            const workspace = handler.model.workspace.workspace orelse return;
            if (std.meta.eql(workspace, commit.location.workspace) and
                handler.model.workspace.find(commit.location.tab_id) != null)
            {
                return error.StalePaneSplitConfirmation;
            }
        },
    }
}

fn exactTab(handler: *const DeliverPaneSplitConfirmationHandler, location: source_namespace.schema.TabLocation) !*source_namespace.tabs_mod.Tab {
    const tab = handler.model.workspace.find(location.tab_id) orelse return error.StalePaneSplitConfirmation;
    if (!std.meta.eql(tab.location, location)) {
        return error.StalePaneSplitConfirmation;
    }

    return tab;
}
