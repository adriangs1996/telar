const Client = @import("../../AttachedClient.zig");
const std = @import("std");
const pane_pastes = @import("../input/pane_pastes.zig");
const pane_focus_reports = @import("../panes/pane_focus_reports.zig");
const request_lifecycle = @import("../../connection/request_lifecycle.zig");
const runtime_transport = @import("../../entrypoints/runtime_io.zig");
const TabDetachmentPlan = @import("../../model/TabDetachmentPlan.zig");

const TabLocation = @import("telar-core").TabLocation;

/// Counts outbound deliveries for an exact detachment plan without mutation. Example: `const required = requiredCapacity(client, &plan);`
pub fn requiredCapacity(client: *Client, plan: *const TabDetachmentPlan) usize {
    var required = @as(usize, @intFromBool(plan.paste_marker_required));
    required += @intFromBool(plan.focus_out_required);
    for (plan.slice()) |pane| {
        required += @intFromBool(pane.attached or request_lifecycle.hasPane(client, .attachment, pane.pane_id));
    }

    return required;
}

/// Finishes paste and focus, detaches in pane order, then commits detachment. Example: `try detach(client, location);`
pub fn detach(client: *Client, location: TabLocation) !void {
    const plan = try client.model.planTabDetachment(location);
    if (plan.owns_paste) {
        const outcome = try pane_pastes.finish(client);
        std.debug.assert(outcome != .ignored);
    }

    if (plan.owns_reported_focus) {
        const outcome = try pane_focus_reports.clear(client);
        std.debug.assert(outcome == .applied);
    }

    for (plan.slice()) |pane| {
        const pending = request_lifecycle.hasPane(client, .attachment, pane.pane_id);
        if (!pane.attached and !pending) {
            continue;
        }

        try runtime_transport.enqueue(client, .{ .detach_pane = .{ .pane_id = pane.pane_id } });
        _ = request_lifecycle.ignoreAttachment(client, pane.pane_id);
        try client.graphics.setPaneVisible(pane.pane_id, false);
    }

    try client.model.commitTabDetachment(plan);
}
