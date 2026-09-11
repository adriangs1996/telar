const EffectsCapture = @This();
const source_namespace = @import("pane_viewport_delivery.zig");
const Effects = @import("PaneViewportDeliveryEffects.zig");
events: [2]source_namespace.Event = undefined,
event_count: usize = 0,
graphics_pane: ?source_namespace.schema.PaneId = null,
visible: ?bool = null,
viewport: ?source_namespace.schema.SetPaneViewport = null,
failure: source_namespace.Failure = .none,

pub fn effects(capture: *EffectsCapture) Effects {
    return .{
        .context = capture,
        .set_graphics_visible = setGraphicsVisible,
        .deliver_viewport = deliverViewport,
    };
}

fn setGraphicsVisible(context: *anyopaque, pane_id: source_namespace.schema.PaneId, visible: bool) !void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    capture.append(.graphics);
    capture.graphics_pane = pane_id;
    capture.visible = visible;

    if (capture.failure == .graphics) {
        return error.GraphicsDeliveryFailed;
    }
}

fn deliverViewport(context: *anyopaque, viewport: source_namespace.schema.SetPaneViewport) !void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    capture.append(.runtime);
    capture.viewport = viewport;

    if (capture.failure == .runtime) {
        return error.RuntimeDeliveryFailed;
    }
}

fn append(capture: *EffectsCapture, event: source_namespace.Event) void {
    capture.events[capture.event_count] = event;
    capture.event_count += 1;
}
