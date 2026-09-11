const EffectsCapture = @This();
const client_model = @import("../../root.zig").model;
const source_namespace = @import("pane_closure_delivery.zig");
const core = @import("telar-core");
const Effects = @import("PaneClosureDeliveryEffects.zig");
const pane_geometry_delivery = @import("pane_geometry_delivery.zig");
const std = @import("std");
model: *client_model.Model,
exit: client_model.PaneExit,
events: [8]source_namespace.Event = undefined,
event_count: usize = 0,
committed_state_observed: bool = true,
geometry_area: core.ui.Rect = .{ .w = 40, .h = 10 },
delivered_resize: ?source_namespace.schema.PaneResize = null,
failure: source_namespace.Failure = .none,

pub fn effects(capture: *EffectsCapture) Effects {
    return .{
        .context = capture,
        .ignore_attachment = ignoreAttachment,
        .complete_close = completeClose,
        .clear_pane_graphics = clearPaneGraphics,
        .invalidate_graphics_placements = invalidateGraphicsPlacements,
        .synchronize_active_resources = synchronizeActiveResources,
        .active_geometry_area = activeGeometryArea,
    };
}

pub fn geometryEffects(capture: *EffectsCapture) pane_geometry_delivery.OfferEffects {
    return .{
        .context = capture,
        .deliver_resize = deliverResize,
    };
}

fn ignoreAttachment(context: *anyopaque, pane_id: source_namespace.schema.PaneId) void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    capture.append(.{ .ignore_attachment = pane_id });
}

fn completeClose(context: *anyopaque, pane_id: source_namespace.schema.PaneId) void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    capture.append(.{ .complete_close = pane_id });
}

fn clearPaneGraphics(context: *anyopaque, pane_id: source_namespace.schema.PaneId) void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    capture.append(.{ .clear_graphics = pane_id });
}

fn invalidateGraphicsPlacements(context: *anyopaque) void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    capture.append(.invalidate_placements);
}

fn synchronizeActiveResources(context: *anyopaque) !void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    capture.append(.synchronize_active_resources);
    if (capture.failure == .active_resources) {
        return error.ActiveResourceSynchronizationFailed;
    }
}

fn activeGeometryArea(context: *anyopaque) core.ui.Rect {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    capture.append(.active_geometry_area);

    return capture.geometry_area;
}

fn deliverResize(context: *anyopaque, resize: source_namespace.schema.PaneResize) !void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    capture.append(.{ .resize = resize.pane_id });
    capture.delivered_resize = resize;
    if (capture.failure == .resize) {
        return error.PaneResizeDeliveryFailed;
    }
}

fn append(capture: *EffectsCapture, event: source_namespace.Event) void {
    capture.committed_state_observed = capture.committed_state_observed and capture.observesCommit();
    capture.events[capture.event_count] = event;
    capture.event_count += 1;
}

fn observesCommit(capture: *const EffectsCapture) bool {
    const version = capture.model.version();
    return switch (capture.exit) {
        .retired => |retirement| observed: {
            const tab = capture.model.workspace.find(retirement.location.tab_id) orelse break :observed false;
            const active = capture.model.workspace.activeConst();
            const tab_active = active != null and std.meta.eql(active.?.location, retirement.location);

            break :observed std.meta.eql(tab.location, retirement.location) and
                capture.model.workspace.tabForPaneConst(retirement.pane_id) == null and
                tab.model.layout.currentRevision() == retirement.layout_revision and
                (tab.model.pane_count == 0) == retirement.tab_empty and
                tab_active == retirement.active and
                version.workspace == retirement.workspace_revision and
                version.tabs == retirement.tabs_revision and
                version.active_tab == retirement.active_tab_revision and
                version.panes == retirement.panes_revision;
        },
        .stale => |stale| capture.model.workspace.tabForPaneConst(stale.pane_id) == null and
            version.workspace == stale.workspace_revision and
            version.tabs == stale.tabs_revision and
            version.active_tab == stale.active_tab_revision and
            version.panes == stale.panes_revision,
    };
}

pub fn eventSlice(capture: *const EffectsCapture) []const source_namespace.Event {
    return capture.events[0..capture.event_count];
}
