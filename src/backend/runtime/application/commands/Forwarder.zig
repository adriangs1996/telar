const std = @import("std");
const RuntimeMetricsType = @import("../../observability/RuntimeMetrics.zig");
const TrackerType = @import("../../../agent/Tracker.zig");
const PaneInputScheduler = @import("PaneInputScheduler.zig");
const PaneType = @import("../../../pane/Pane.zig");
const mark_module = @import("telar-core").mark;
const enabled_module = @import("telar-core").enabled;
const pane_mod = @import("../../../pane/pane_namespace.zig");
/// The attachment-independent half of pane input: observation first, then the
/// bounded PTY queue. Shared by attached-client input and control requests
/// that resolve panes by exact generation.
const Forwarder = @This();

io: std.Io,
metrics: *RuntimeMetricsType,
agent_input: ?*TrackerType,
scheduler: PaneInputScheduler,

/// Offers one input message to the bounded history observer before making
/// it available to the PTY writer. This ordering prevents child output from
/// overtaking the input observation. PTY queue saturation drops the complete
/// message while preserving previously queued bytes.
///
/// ```zig
/// try forwarder.forward(pane, "help\r");
/// ```
pub inline fn forward(forwarder: *const Forwarder, pane: *PaneType, bytes: []const u8) !void {
    mark_module(forwarder.io, .input_forward);
    if (comptime enabled_module) {
        forwarder.metrics.input_events += 1;
        forwarder.metrics.input_bytes += bytes.len;
    }

    if (forwarder.agent_input) |tracker| {
        _ = tracker.observeInput(pane.key(), bytes);
    }

    mark_module(forwarder.io, .foreground_start);
    const foreground = pane.session.shellForeground() orelse false;
    mark_module(forwarder.io, .foreground_done);
    pane.queueHistoryInput(.{
        .bytes = bytes,
        .shell_foreground = foreground,
        .clock = pane_mod.historyClock(forwarder.io),
    });
    mark_module(forwarder.io, .input_observed);
    try forwarder.scheduler.observation(forwarder.scheduler.context, pane);

    _ = pane.queuePtyInput(bytes);
    try forwarder.scheduler.input(forwarder.scheduler.context, pane);
}
