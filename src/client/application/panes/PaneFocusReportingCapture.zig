const ModelType = @import("../../model/Model.zig");
const ReportedPaneFocusType = @import("../../model/ReportedPaneFocus.zig");
const Delivery = @import("PaneFocusDelivery.zig");
const PaneFocusReportingEffects = @import("PaneFocusReportingEffects.zig");
const std = @import("std");
const Capture = @This();

model: *const ModelType,
expected: ?ReportedPaneFocusType,
deliveries: [4]Delivery = undefined,
delivery_count: usize = 0,
all_observed_commit: bool = true,
fail: bool = false,

pub fn port(capture: *Capture) PaneFocusReportingEffects {
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
