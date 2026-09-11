//! Application command for resizing one attached pane.

const std = @import("std");
const core = @import("telar-core");
const pane_mod = @import("../../../pane/root.zig");
const attachment_mod = @import("../../attachment/root.zig");

pub const schema = core.schema;
pub const AttachmentStore = attachment_mod.AttachmentStore;

pub const PaneResize = @import("PaneResize.zig");

pub const PaneResizeResult = enum {
    /// The request completed its applicable effects, including deferred
    /// application, pane closure, or disposal of a failed client projection.
    handled,
    pane_not_attached,
    geometry_rejected,
};

pub const GeometryLease = @import("PaneResizeGeometryLease.zig");

pub const Scheduler = @import("PaneResizeScheduler.zig");

pub const PaneResizeHandler = @import("PaneResizeHandler.zig");
