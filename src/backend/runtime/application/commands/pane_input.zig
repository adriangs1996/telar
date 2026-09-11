//! Application command for forwarding input to one attached pane.

const std = @import("std");
const core = @import("telar-core");
const agent_mod = @import("../../../agent/root.zig");
const pane_mod = @import("../../../pane/root.zig");
const attachment_mod = @import("../../attachment/root.zig");
const telemetry_mod = @import("../../observability/root.zig").telemetry;

pub const Io = std.Io;
pub const AttachmentStore = attachment_mod.AttachmentStore;
pub const RuntimeMetrics = telemetry_mod.RuntimeMetrics;
pub const schema = core.schema;
pub const diagnostics = core.diagnostics;

pub const PaneInput = @import("PaneInput.zig");

/// Attachment-validation outcome. `handled` includes a whole-message drop by
/// the bounded PTY queue because that backpressure policy is not a stale input.
pub const PaneInputResult = enum {
    handled,
    pane_not_attached,
    pane_exited,
};

pub const Scheduler = @import("PaneInputScheduler.zig");

pub const Forwarder = @import("Forwarder.zig");

pub const PaneInputHandler = @import("PaneInputHandler.zig");
