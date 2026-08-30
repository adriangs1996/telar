//! Application command for forwarding input to one attached pane.

const std = @import("std");
const core = @import("telar-core");
const agent_mod = @import("../../agent/root.zig");
const pane_mod = @import("../../pane/root.zig");
const attachment_mod = @import("../attachment.zig");
const telemetry_mod = @import("../telemetry.zig");

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

pub const PaneInputHandler = struct {
    io: Io,
    attachments: *AttachmentStore,
    metrics: *RuntimeMetrics,
    agent_input: ?*agent_mod.Tracker,
    scheduler: Scheduler,

    /// Offers one input message to the bounded history observer before making
    /// it available to the PTY writer. This ordering prevents child output from
    /// overtaking the input observation. PTY queue saturation drops the complete
    /// message while preserving previously queued bytes.
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

        if (comptime diagnostics.enabled) {
            handler.metrics.input_events += 1;
            handler.metrics.input_bytes += command.bytes.len;
        }

        if (handler.agent_input) |tracker| {
            _ = tracker.observeInput(pane.key(), command.bytes);
        }

        pane.queueHistoryInput(
            command.bytes,
            pane.session.shellForeground() orelse false,
            pane_mod.historyClock(handler.io),
        );
        try handler.scheduler.observation(handler.scheduler.context, pane);

        _ = pane.queuePtyInput(command.bytes);
        try handler.scheduler.input(handler.scheduler.context, pane);

        return .handled;
    }
};
