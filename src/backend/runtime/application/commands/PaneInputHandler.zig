const PaneInputHandler = @This();
const source_namespace = @import("pane_input.zig");
const agent_mod = @import("../../../agent/root.zig");
const Scheduler = @import("PaneInputScheduler.zig");
const PaneInput = @import("PaneInput.zig");
const Forwarder = @import("Forwarder.zig");
io: source_namespace.Io,
attachments: *source_namespace.AttachmentStore,
metrics: *source_namespace.RuntimeMetrics,
agent_input: ?*agent_mod.Tracker,
scheduler: Scheduler,

/// Validates the requesting client's attachment, then forwards the bytes.
///
/// ```zig
/// const result = try handler.execute(.{ .pane_id = pane_id, .bytes = "help\r" });
/// ```
pub inline fn execute(handler: *PaneInputHandler, command: PaneInput) !source_namespace.PaneInputResult {
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
