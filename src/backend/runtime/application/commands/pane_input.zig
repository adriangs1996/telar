//! Application command for forwarding input to one attached pane.

const std = @import("std");
const core = @import("telar-core");
const agent_mod = @import("../../../agent/root.zig");
const pane_mod = @import("../../../pane/root.zig");
const attachment_mod = @import("../../attachment/root.zig");
const telemetry_mod = @import("../../observability/root.zig").telemetry;

const Io = std.Io;
const AttachmentStore = attachment_mod.AttachmentStore;
const RuntimeMetrics = telemetry_mod.RuntimeMetrics;
const schema = core.schema;
const diagnostics = core.diagnostics;

pub const PaneInput = struct {
    pane_id: schema.PaneId,
    bytes: []const u8,
};

/// Attachment-validation outcome. `handled` includes a whole-message drop by
/// the bounded PTY queue because that backpressure policy is not a stale input.
pub const PaneInputResult = enum {
    handled,
    pane_not_attached,
    pane_exited,
};

pub const Scheduler = struct {
    context: *anyopaque,
    observation: *const fn (*anyopaque, *pane_mod.Pane) anyerror!void,
    input: *const fn (*anyopaque, *pane_mod.Pane) anyerror!void,
};

/// The attachment-independent half of pane input: observation first, then the
/// bounded PTY queue. Shared by attached-client input and control requests
/// that resolve panes by exact generation.
pub const Forwarder = struct {
    io: Io,
    metrics: *RuntimeMetrics,
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
        if (comptime diagnostics.enabled) {
            forwarder.metrics.input_events += 1;
            forwarder.metrics.input_bytes += bytes.len;
        }

        if (forwarder.agent_input) |tracker| {
            _ = tracker.observeInput(pane.key(), bytes);
        }

        pane.queueHistoryInput(.{
            .bytes = bytes,
            .shell_foreground = pane.session.shellForeground() orelse false,
            .clock = pane_mod.historyClock(forwarder.io),
        });
        try forwarder.scheduler.observation(forwarder.scheduler.context, pane);

        _ = pane.queuePtyInput(bytes);
        try forwarder.scheduler.input(forwarder.scheduler.context, pane);
    }
};

pub const PaneInputHandler = struct {
    io: Io,
    attachments: *AttachmentStore,
    metrics: *RuntimeMetrics,
    agent_input: ?*agent_mod.Tracker,
    scheduler: Scheduler,

    /// Validates the requesting client's attachment, then forwards the bytes.
    ///
    /// ```zig
    /// const result = try handler.execute(.{ .pane_id = pane_id, .bytes = "help\r" });
    /// ```
    pub inline fn execute(handler: *PaneInputHandler, command: PaneInput) !PaneInputResult {
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
};
