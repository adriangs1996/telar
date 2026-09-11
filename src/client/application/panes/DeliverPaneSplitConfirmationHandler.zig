const ModelType = @import("../../model/Model.zig");
const OfferEffectsType = @import("OfferEffects.zig");
const PaneSplitConfirmationDeliveryEffects = @import("PaneSplitConfirmationDeliveryEffects.zig");
const PaneSplitCommitType = @import("../../model/PaneSplitCommit.zig");
const OfferPaneGeometryHandlerType = @import("OfferPaneGeometryHandler.zig");
const std = @import("std");
const TabLocationType = @import("telar-core").TabLocation;
const TabType = @import("../../workspace/Tab.zig");
const DeliverPaneSplitConfirmationHandler = @This();

model: *ModelType,
geometry_effects: OfferEffectsType,
effects: PaneSplitConfirmationDeliveryEffects,

/// Validates one exact split commit before applying the resource policy
/// selected by its active, inactive or stale disposition.
///
/// ```zig
/// try handler.execute(commit);
/// ```
pub fn execute(handler: *DeliverPaneSplitConfirmationHandler, commit: PaneSplitCommitType) !void {
    try handler.validate(commit);

    switch (commit.disposition) {
        .active => {
            const tab = try handler.exactTab(commit.location);
            var offer_geometry: OfferPaneGeometryHandlerType = .{
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

fn validate(handler: *const DeliverPaneSplitConfirmationHandler, commit: PaneSplitCommitType) !void {
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

fn exactTab(handler: *const DeliverPaneSplitConfirmationHandler, location: TabLocationType) !*TabType {
    const tab = handler.model.workspace.find(location.tab_id) orelse return error.StalePaneSplitConfirmation;
    if (!std.meta.eql(tab.location, location)) {
        return error.StalePaneSplitConfirmation;
    }

    return tab;
}
