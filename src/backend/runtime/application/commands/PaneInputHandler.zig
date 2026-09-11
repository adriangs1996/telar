const std = @import("std");
const AttachmentStoreType = @import("../../attachment/AttachmentStore.zig");
const RuntimeMetricsType = @import("../../observability/RuntimeMetrics.zig");
const TrackerType = @import("../../../agent/Tracker.zig");
const PaneInputScheduler = @import("PaneInputScheduler.zig");
const PaneInput = @import("PaneInput.zig");
const pane_input = @import("pane_input.zig");
const Forwarder = @import("Forwarder.zig");
const PaneInputHandler = @This();

io: std.Io,
attachments: *AttachmentStoreType,
metrics: *RuntimeMetricsType,
agent_input: ?*TrackerType,
scheduler: PaneInputScheduler,

/// Validates the requesting client's attachment, then forwards the bytes.
///
/// ```zig
/// const result = try handler.execute(.{ .pane_id = pane_id, .bytes = "help\r" });
/// ```
pub inline fn execute(handler: *PaneInputHandler, command: PaneInput) !pane_input.PaneInputResult {
    const attachment = handler.attachments.find(command.pane_id) orelse return .pane_not_attached;
    const pane = attachment.pane;

    if (pane.exit != null) {
        return .pane_exited;
    }

    try handler.forwarder().forward(pane, command.bytes);
    return .handled;
}

/// Exposes the attachment-independent forwarding half of this handler.
///
/// ```zig
/// try handler.forwarder().forward(pane, bytes);
/// ```
pub fn forwarder(handler: *const PaneInputHandler) Forwarder {
    return .{
        .io = handler.io,
        .metrics = handler.metrics,
        .agent_input = handler.agent_input,
        .scheduler = handler.scheduler,
    };
}
