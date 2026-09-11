const Capture = @This();
const client_model = @import("../../root.zig").model;
const Delivery = @import("Delivery.zig");
const Effects = @import("PaneFocusReportingEffects.zig");
const std = @import("std");
model: *const client_model.Model,
expected: ?client_model.ReportedPaneFocus,
deliveries: [4]Delivery = undefined,
delivery_count: usize = 0,
all_observed_commit: bool = true,
fail: bool = false,

pub fn port(capture: *Capture) Effects {
    return .{ .context = capture, .deliver = deliver };
}

fn deliver(raw_context: *anyopaque, delivery: Delivery) !void {
    const capture: *Capture = @ptrCast(@alignCast(raw_context));
    capture.all_observed_commit = capture.all_observed_commit and
        std.meta.eql(capture.expected, capture.model.reportedPaneFocus());
    capture.deliveries[capture.delivery_count] = delivery;
    capture.delivery_count += 1;

    if (capture.fail) {
        return error.FocusReportFailed;
    }
}
