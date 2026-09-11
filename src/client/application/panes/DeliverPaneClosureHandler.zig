const DeliverPaneClosureHandler = @This();
const client_model = @import("../../root.zig").model;
const pane_geometry_delivery = @import("pane_geometry_delivery.zig");
const Effects = @import("PaneClosureDeliveryEffects.zig");
const pane_resource_release = @import("pane_resource_release.zig");
const std = @import("std");
const source_namespace = @import("pane_closure_delivery.zig");
model: *client_model.Model,
geometry_effects: pane_geometry_delivery.OfferEffects,
effects: Effects,

/// Validates one exact pane-exit commit before retiring request and pane
/// resources, then repairs active focus and geometry when required.
///
/// ```zig
/// try handler.execute(exit);
/// ```
pub fn execute(handler: *DeliverPaneClosureHandler, exit: client_model.PaneExit) !void {
    try handler.validate(exit);

    const pane_id = switch (exit) {
        .retired => |retirement| retirement.pane_id,
        .stale => |stale| stale.pane_id,
    };
    handler.effects.ignore_attachment(handler.effects.context, pane_id);
    handler.effects.complete_close(handler.effects.context, pane_id);

    var release_pane: pane_resource_release.ReleasePaneResourcesHandler = .{
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
    var offer_geometry: pane_geometry_delivery.OfferPaneGeometryHandler = .{
        .effects = handler.geometry_effects,
    };
    _ = try offer_geometry.execute(&tab.model, area);
}

fn validate(handler: *const DeliverPaneClosureHandler, exit: client_model.PaneExit) !void {
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

fn exactTab(handler: *const DeliverPaneClosureHandler, location: source_namespace.schema.TabLocation) !*source_namespace.tabs_mod.Tab {
    const tab = handler.model.workspace.find(location.tab_id) orelse return error.StalePaneExit;
    if (!std.meta.eql(tab.location, location)) {
        return error.StalePaneExit;
    }

    return tab;
}
