const Capture = @This();
const client_model = @import("../../root.zig").model;
const source_namespace = @import("pane_paste.zig");
const Effects = @import("PanePasteEffects.zig");
model: *const client_model.Model,
deliveries: [4]source_namespace.Delivery = undefined,
delivery_count: usize = 0,
all_observed_active: bool = true,
available: bool = true,
fail: bool = false,

pub fn port(capture: *Capture) Effects {
    return .{ .context = capture, .deliver = deliver };
}

fn deliver(raw_context: *anyopaque, delivery: source_namespace.Delivery) !bool {
    const capture: *Capture = @ptrCast(@alignCast(raw_context));
    capture.all_observed_active = capture.all_observed_active and capture.model.panePasteActive();
    capture.deliveries[capture.delivery_count] = delivery;
    capture.delivery_count += 1;
    if (capture.fail) {
        return error.PasteDeliveryFailed;
    }

    return capture.available;
}
