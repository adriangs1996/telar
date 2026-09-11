const ModelType = @import("../../model/Model.zig");
const pane_geometry_delivery = @import("pane_geometry_delivery.zig");
const max_panes_per_tab = @import("telar-core").max_panes_per_tab;
const PaneResizeType = @import("telar-core").PaneResize;
const PaneBottomReservationType = @import("../../workspace/PaneBottomReservation.zig");
const OfferEffects = @import("OfferEffects.zig");
const PaneGeometryDeliveryEffects = @import("PaneGeometryDeliveryEffects.zig");
const RectType = @import("telar-core").Rect;
const EffectCapture = @This();

model: ?*const ModelType = null,
expected_revision: u64 = 0,
events: [5]pane_geometry_delivery.Event = undefined,
event_count: usize = 0,
resizes: [max_panes_per_tab]PaneResizeType = undefined,
resize_count: usize = 0,
committed_geometry_observed: bool = true,
fail_resize: ?usize = null,
bottom_reservation: ?PaneBottomReservationType = null,

pub fn offerEffects(capture: *EffectCapture) OfferEffects {
    return .{
        .context = capture,
        .deliver_resize = deliverResize,
        .bottom_reservation = bottomReservation,
    };
}

pub fn effects(capture: *EffectCapture) PaneGeometryDeliveryEffects {
    return .{
        .context = capture,
        .invalidate_graphics_placements = invalidateGraphicsPlacements,
        .request_visible_attachments = requestVisibleAttachments,
        .deliver_resize = deliverResize,
        .bottom_reservation = bottomReservation,
    };
}

fn bottomReservation(raw_context: *anyopaque) ?PaneBottomReservationType {
    const capture: *EffectCapture = @ptrCast(@alignCast(raw_context));

    return capture.bottom_reservation;
}

fn invalidateGraphicsPlacements(raw_context: *anyopaque) void {
    const capture: *EffectCapture = @ptrCast(@alignCast(raw_context));
    capture.append(.invalidate_placements);
}

fn requestVisibleAttachments(raw_context: *anyopaque, _: RectType) !void {
    const capture: *EffectCapture = @ptrCast(@alignCast(raw_context));
    capture.append(.request_attachments);
}

fn deliverResize(raw_context: *anyopaque, resize: PaneResizeType) !void {
    const capture: *EffectCapture = @ptrCast(@alignCast(raw_context));
    capture.append(.resize);
    capture.resizes[capture.resize_count] = resize;
    capture.resize_count += 1;

    if (capture.fail_resize == capture.resize_count) {
        return error.PaneResizeDeliveryFailed;
    }
}

fn append(capture: *EffectCapture, event: pane_geometry_delivery.Event) void {
    if (capture.model) |model| {
        capture.committed_geometry_observed = capture.committed_geometry_observed and
            model.version().panes == capture.expected_revision;
    }

    capture.events[capture.event_count] = event;
    capture.event_count += 1;
}

pub fn reset(capture: *EffectCapture) void {
    capture.event_count = 0;
    capture.resize_count = 0;
}

pub fn eventSlice(capture: *const EffectCapture) []const pane_geometry_delivery.Event {
    return capture.events[0..capture.event_count];
}
