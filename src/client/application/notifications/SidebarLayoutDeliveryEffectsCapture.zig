const ModelType = @import("../../model/Model.zig");
const SidebarLayoutType = @import("../../model/SidebarLayout.zig");
const sidebar_layout_delivery = @import("sidebar_layout_delivery.zig");
const MultiplexerModel = @import("../../workspace/MultiplexerModel.zig");
const SidebarLayoutDeliveryEffects = @import("SidebarLayoutDeliveryEffects.zig");
const EffectsCapture = @This();

model: *const ModelType,
expected: SidebarLayoutType,
events: [3]sidebar_layout_delivery.Event = undefined,
event_count: usize = 0,
projected_visible: ?bool = null,
projected_width: ?u16 = null,
offered_model: ?*MultiplexerModel = null,
observed_commit: bool = true,
fail_geometry: bool = false,

pub fn effects(capture: *EffectsCapture) SidebarLayoutDeliveryEffects {
    return .{
        .context = capture,
        .project_view = projectView,
        .invalidate_graphics_placements = invalidateGraphicsPlacements,
        .offer_pane_geometry = offerPaneGeometry,
    };
}

fn projectView(context: *anyopaque, visible: bool, width: u16) void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    capture.record(.project_view);
    capture.projected_visible = visible;
    capture.projected_width = width;
}

fn invalidateGraphicsPlacements(context: *anyopaque) void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    capture.record(.invalidate_graphics);
}

fn offerPaneGeometry(context: *anyopaque, model: *MultiplexerModel) !void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    capture.record(.pane_geometry);
    capture.offered_model = model;

    if (capture.fail_geometry) {
        return error.PaneGeometryDeliveryFailed;
    }
}

fn record(capture: *EffectsCapture, event: sidebar_layout_delivery.Event) void {
    capture.observed_commit = capture.observed_commit and
        capture.model.sidebarVisible() == capture.expected.visible and
        capture.model.sidebarWidth() == capture.expected.width and
        capture.model.version().chrome == capture.expected.chrome_revision;
    capture.events[capture.event_count] = event;
    capture.event_count += 1;
}
