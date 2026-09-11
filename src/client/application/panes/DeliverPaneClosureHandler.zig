const ModelType = @import("../../model/Model.zig");
const OfferEffectsType = @import("OfferEffects.zig");
const PaneClosureDeliveryEffects = @import("PaneClosureDeliveryEffects.zig");
const types = @import("../../model/types.zig");
const ReleasePaneResourcesHandlerType = @import("ReleasePaneResourcesHandler.zig");
const OfferPaneGeometryHandlerType = @import("OfferPaneGeometryHandler.zig");
const std = @import("std");
const TabLocationType = @import("telar-core").TabLocation;
const TabType = @import("../../workspace/Tab.zig");
const DeliverPaneClosureHandler = @This();

model: *ModelType,
geometry_effects: OfferEffectsType,
effects: PaneClosureDeliveryEffects,

/// Validates one exact pane-exit commit before retiring request and pane
/// resources, then repairs active focus and geometry when required.
///
/// ```zig
/// try handler.execute(exit);
/// ```
pub fn execute(handler: *DeliverPaneClosureHandler, exit: types.PaneExit) !void {
    try handler.validate(exit);

    const pane_id = switch (exit) {
        .retired => |retirement| retirement.pane_id,
        .stale => |stale| stale.pane_id,
    };
    handler.effects.ignore_attachment(handler.effects.context, pane_id);
    handler.effects.complete_close(handler.effects.context, pane_id);

    var release_pane: ReleasePaneResourcesHandlerType = .{
        .model = handler.model,
        .effects = .{
            .context = handler.effects.context,
            .clear_graphics = handler.effects.clear_pane_graphics,
        },
    };
    _ = release_pane.execute(pane_id);

    const retirement = switch (exit) {
        .retired => |retirement| retirement,
        .stale => return,
    };
    if (!retirement.active) {
        return;
    }

    handler.effects.invalidate_graphics_placements(handler.effects.context);
    try handler.effects.synchronize_active_resources(handler.effects.context);
    if (retirement.tab_empty) {
        return;
    }

    const tab = try handler.exactTab(retirement.location);
    const area = handler.effects.active_geometry_area(handler.effects.context);
    var offer_geometry: OfferPaneGeometryHandlerType = .{
        .effects = handler.geometry_effects,
    };
    _ = try offer_geometry.execute(&tab.model, area);
}

fn validate(handler: *const DeliverPaneClosureHandler, exit: types.PaneExit) !void {
    const version = handler.model.version();
    switch (exit) {
        .retired => |retirement| {
            const tab = try handler.exactTab(retirement.location);
            const active = handler.model.workspace.activeConst();
            const tab_active = active != null and std.meta.eql(active.?.location, retirement.location);
            if (version.workspace != retirement.workspace_revision or
                version.tabs != retirement.tabs_revision or
                version.active_tab != retirement.active_tab_revision or
                version.panes != retirement.panes_revision or
                tab.model.layout.currentRevision() != retirement.layout_revision or
                tab_active != retirement.active or
                (tab.model.pane_count == 0) != retirement.tab_empty or
                handler.model.workspace.tabForPaneConst(retirement.pane_id) != null)
            {
                return error.StalePaneExit;
            }
        },
        .stale => |stale| {
            if (version.workspace != stale.workspace_revision or
                version.tabs != stale.tabs_revision or
                version.active_tab != stale.active_tab_revision or
                version.panes != stale.panes_revision or
                handler.model.workspace.tabForPaneConst(stale.pane_id) != null)
            {
                return error.StalePaneExit;
            }
        },
    }
}

fn exactTab(handler: *const DeliverPaneClosureHandler, location: TabLocationType) !*TabType {
    const tab = handler.model.workspace.find(location.tab_id) orelse return error.StalePaneExit;
    if (!std.meta.eql(tab.location, location)) {
        return error.StalePaneExit;
    }

    return tab;
}
