const pane_viewport_delivery = @import("pane_viewport_delivery.zig");
const PaneIdType = @import("telar-core").PaneId;
const SetPaneViewportType = @import("telar-core").SetPaneViewport;
const PaneViewportDeliveryEffects = @import("PaneViewportDeliveryEffects.zig");
const EffectsCapture = @This();

events: [2]pane_viewport_delivery.Event = undefined,
event_count: usize = 0,
graphics_pane: ?PaneIdType = null,
visible: ?bool = null,
viewport: ?SetPaneViewportType = null,
failure: pane_viewport_delivery.Failure = .none,

pub fn effects(capture: *EffectsCapture) PaneViewportDeliveryEffects {
    return .{
        .context = capture,
        .set_graphics_visible = setGraphicsVisible,
        .deliver_viewport = deliverViewport,
    };
}

fn setGraphicsVisible(context: *anyopaque, pane_id: PaneIdType, visible: bool) !void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    capture.append(.graphics);
    capture.graphics_pane = pane_id;
    capture.visible = visible;

    if (capture.failure == .graphics) {
        return error.GraphicsDeliveryFailed;
    }
}

fn deliverViewport(context: *anyopaque, viewport: SetPaneViewportType) !void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    capture.append(.runtime);
    capture.viewport = viewport;

    if (capture.failure == .runtime) {
        return error.RuntimeDeliveryFailed;
    }
}

fn append(capture: *EffectsCapture, event: pane_viewport_delivery.Event) void {
    capture.events[capture.event_count] = event;
    capture.event_count += 1;
}
