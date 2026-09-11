/// The attachment-independent half of pane input: observation first, then the
/// bounded PTY queue. Shared by attached-client input and control requests
/// that resolve panes by exact generation.
const Forwarder = @This();
const source_namespace = @import("pane_input.zig");
const agent_mod = @import("../../../agent/root.zig");
const Scheduler = @import("PaneInputScheduler.zig");
const pane_mod = @import("../../../pane/root.zig");
const core = @import("telar-core");
io: source_namespace.Io,
metrics: *source_namespace.RuntimeMetrics,
agent_input: ?*agent_mod.Tracker,
scheduler: Scheduler,

/// Offers one input message to the bounded history observer before making
/// it available to the PTY writer. This ordering prevents child output from
/// overtaking the input observation. PTY queue saturation drops the complete
/// message while preserving previously queued bytes.
///
/// ```zig
/// try forwarder.forward(pane, "help\r");
/// ```
pub inline fn forward(forwarder: *const Forwarder, pane: *pane_mod.Pane, bytes: []const u8) !void {
    core.echo_trace.mark(forwarder.io, .input_forward);
    if (comptime source_namespace.diagnostics.enabled) {
        forwarder.metrics.input_events += 1;
        forwarder.metrics.input_bytes += bytes.len;
    }

    if (forwarder.agent_input) |tracker| {
        _ = tracker.observeInput(pane.key(), bytes);
    }

    core.echo_trace.mark(forwarder.io, .foreground_start);
    const foreground = pane.session.shellForeground() orelse false;
    core.echo_trace.mark(forwarder.io, .foreground_done);
    pane.queueHistoryInput(.{
        .bytes = bytes,
        .shell_foreground = foreground,
        .clock = pane_mod.historyClock(forwarder.io),
    });
    core.echo_trace.mark(forwarder.io, .input_observed);
    try forwarder.scheduler.observation(forwarder.scheduler.context, pane);

    _ = pane.queuePtyInput(bytes);
    try forwarder.scheduler.input(forwarder.scheduler.context, pane);
}
