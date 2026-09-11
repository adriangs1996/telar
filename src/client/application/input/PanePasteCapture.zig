const ModelType = @import("../../model/Model.zig");
const pane_paste = @import("pane_paste.zig");
const PanePasteEffects = @import("PanePasteEffects.zig");
const Capture = @This();

model: *const ModelType,
deliveries: [4]pane_paste.Delivery = undefined,
delivery_count: usize = 0,
all_observed_active: bool = true,
available: bool = true,
fail: bool = false,

pub fn port(capture: *Capture) PanePasteEffects {
    return .{ .context = capture, .deliver = deliver };
}

fn deliver(raw_context: *anyopaque, delivery: pane_paste.Delivery) !bool {
    const capture: *Capture = @ptrCast(@alignCast(raw_context));
    capture.all_observed_active = capture.all_observed_active and capture.model.panePasteActive();
    capture.deliveries[capture.delivery_count] = delivery;
    capture.delivery_count += 1;
    if (capture.fail) {
        return error.PasteDeliveryFailed;
    }

    return capture.available;
}
