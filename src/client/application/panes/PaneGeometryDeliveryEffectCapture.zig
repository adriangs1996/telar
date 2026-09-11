const EffectCapture = @This();
const client_model = @import("../../root.zig").model;
const source_namespace = @import("pane_geometry_delivery.zig");
const OfferEffects = @import("OfferEffects.zig");
const Effects = @import("PaneGeometryDeliveryEffects.zig");
model: ?*const client_model.Model = null,
expected_revision: u64 = 0,
events: [5]source_namespace.Event = undefined,
event_count: usize = 0,
resizes: [source_namespace.multiplexer.max_panes]source_namespace.schema.PaneResize = undefined,
resize_count: usize = 0,
committed_geometry_observed: bool = true,
fail_resize: ?usize = null,
bottom_reservation: ?source_namespace.layout_mod.PaneBottomReservation = null,

pub fn offerEffects(capture: *EffectCapture) OfferEffects {
    return .{
        .context = capture,
        .deliver_resize = deliverResize,
        .bottom_reservation = bottomReservation,
    };
}

pub fn effects(capture: *EffectCapture) Effects {
    return .{
        .context = capture,
        .invalidate_graphics_placements = invalidateGraphicsPlacements,
        .request_visible_attachments = requestVisibleAttachments,
        .deliver_resize = deliverResize,
        .bottom_reservation = bottomReservation,
    };
}

fn bottomReservation(raw_context: *anyopaque) ?source_namespace.layout_mod.PaneBottomReservation {
    const capture: *EffectCapture = @ptrCast(@alignCast(raw_context));

    return capture.bottom_reservation;
}

fn invalidateGraphicsPlacements(raw_context: *anyopaque) void {
    const capture: *EffectCapture = @ptrCast(@alignCast(raw_context));
    capture.append(.invalidate_placements);
}

fn requestVisibleAttachments(raw_context: *anyopaque, _: source_namespace.ui.Rect) !void {
    const capture: *EffectCapture = @ptrCast(@alignCast(raw_context));
    capture.append(.request_attachments);
}

fn deliverResize(raw_context: *anyopaque, resize: source_namespace.schema.PaneResize) !void {
    const capture: *EffectCapture = @ptrCast(@alignCast(raw_context));
    capture.append(.resize);
    capture.resizes[capture.resize_count] = resize;
    capture.resize_count += 1;

    if (capture.fail_resize == capture.resize_count) {
        return error.PaneResizeDeliveryFailed;
    }
}

fn append(capture: *EffectCapture, event: source_namespace.Event) void {
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

pub fn eventSlice(capture: *const EffectCapture) []const source_namespace.Event {
    return capture.events[0..capture.event_count];
}
