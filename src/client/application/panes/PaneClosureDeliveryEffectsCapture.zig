const ModelType = @import("../../model/Model.zig");
const types = @import("../../model/types.zig");
const pane_closure_delivery = @import("pane_closure_delivery.zig");
const RectType = @import("telar-core").Rect;
const PaneResizeType = @import("telar-core").PaneResize;
const PaneClosureDeliveryEffects = @import("PaneClosureDeliveryEffects.zig");
const OfferEffectsType = @import("OfferEffects.zig");
const PaneIdType = @import("telar-core").PaneId;
const std = @import("std");
const EffectsCapture = @This();

model: *ModelType,
exit: types.PaneExit,
events: [8]pane_closure_delivery.Event = undefined,
event_count: usize = 0,
committed_state_observed: bool = true,
geometry_area: RectType = .{ .w = 40, .h = 10 },
delivered_resize: ?PaneResizeType = null,
failure: pane_closure_delivery.Failure = .none,

pub fn effects(capture: *EffectsCapture) PaneClosureDeliveryEffects {
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

pub fn geometryEffects(capture: *EffectsCapture) OfferEffectsType {
    return .{
        .context = capture,
        .deliver_resize = deliverResize,
    };
}

fn ignoreAttachment(context: *anyopaque, pane_id: PaneIdType) void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    capture.append(.{ .ignore_attachment = pane_id });
}

fn completeClose(context: *anyopaque, pane_id: PaneIdType) void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    capture.append(.{ .complete_close = pane_id });
}

fn clearPaneGraphics(context: *anyopaque, pane_id: PaneIdType) void {
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

fn activeGeometryArea(context: *anyopaque) RectType {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    capture.append(.active_geometry_area);

    return capture.geometry_area;
}

fn deliverResize(context: *anyopaque, resize: PaneResizeType) !void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    capture.append(.{ .resize = resize.pane_id });
    capture.delivered_resize = resize;
    if (capture.failure == .resize) {
        return error.PaneResizeDeliveryFailed;
    }
}

fn append(capture: *EffectsCapture, event: pane_closure_delivery.Event) void {
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

pub fn eventSlice(capture: *const EffectsCapture) []const pane_closure_delivery.Event {
    return capture.events[0..capture.event_count];
}
