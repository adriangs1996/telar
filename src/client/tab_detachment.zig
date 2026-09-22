//! Bounded delivery count for a captured tab and its pending attachments.
const TabDetachmentPlan = @import("model/TabDetachmentPlan.zig");
const Tracker = @import("connection/Tracker.zig");

/// Counts outbound deliveries for an exact detachment plan without mutation. Example: `const required = requiredCapacity(&plan, &tracker);`
pub fn requiredCapacity(plan: *const TabDetachmentPlan, tracker: *const Tracker) usize {
    var required = @as(usize, @intFromBool(plan.paste_marker_required));
    required += @intFromBool(plan.focus_out_required);
    for (plan.slice()) |pane| {
        required += @intFromBool(pane.attached or tracker.hasPane(.attachment, pane.pane_id));
    }

    return required;
}
