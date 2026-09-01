//! Application command for resizing one attached pane.

const std = @import("std");
const core = @import("telar-core");
const pane_mod = @import("../../../pane/root.zig");
const attachment_mod = @import("../../attachment/root.zig");

const schema = core.schema;
const AttachmentStore = attachment_mod.AttachmentStore;

pub const PaneResize = struct {
    pane_id: schema.PaneId,
    size: schema.TerminalSize,
};

pub const PaneResizeResult = enum {
    /// The request completed its applicable effects, including deferred
    /// application, pane closure, or disposal of a failed client projection.
    handled,
    pane_not_attached,
    geometry_rejected,
};

pub const GeometryLease = struct {
    context: *anyopaque,
    holds: *const fn (*anyopaque, schema.WorkspaceLocation) bool,
    release: *const fn (*anyopaque, schema.WorkspaceLocation) void,
};

pub const Scheduler = struct {
    context: *anyopaque,
    observation: *const fn (*anyopaque, *pane_mod.Pane) anyerror!void,
    media: *const fn (*anyopaque, *pane_mod.Pane) anyerror!void,
    response: *const fn (*anyopaque, *pane_mod.Pane) anyerror!void,
};

pub const PaneResizeHandler = struct {
    attachments: *AttachmentStore,
    geometry: GeometryLease,
    scheduler: Scheduler,

    /// Applies an authorized resize immediately while ingestion is idle, then
    /// synchronizes observation, media, and the client's cell buffers in that
    /// order. An active ingest keeps the resize pending for its completion
    /// handler. Local pane resize failure closes the pane; attachment allocation
    /// failure detaches only this client's disposable projection.
    ///
    /// ```zig
    /// const result = try handler.execute(.{ .pane_id = pane_id, .size = size });
    /// ```
    pub fn execute(handler: *PaneResizeHandler, command: PaneResize) !PaneResizeResult {
        const attachment = handler.attachments.find(command.pane_id) orelse return .pane_not_attached;
        const pane = attachment.pane;

        if (!handler.geometry.holds(handler.geometry.context, pane.location.workspace)) {
            return .geometry_rejected;
        }

        try pane.requestResize(command.size);

        if (pane.ingest_pending) {
            return .handled;
        }

        pane.applyPendingResize() catch {
            _ = pane.requestClose();
            return .handled;
        };
        try handler.scheduler.observation(handler.scheduler.context, pane);
        try handler.scheduler.media(handler.scheduler.context, pane);

        _ = attachment.resizeIfNeeded() catch {
            handler.detachFailedProjection(command.pane_id);
            return .handled;
        };

        try handler.scheduler.response(handler.scheduler.context, pane);
        return .handled;
    }

    fn detachFailedProjection(handler: *PaneResizeHandler, pane_id: schema.PaneId) void {
        const detached = handler.attachments.detach(pane_id) orelse return;

        if (!detached.last_attachment) {
            return;
        }

        const left_workspace = handler.attachments.leaveWorkspace(detached.workspace);
        std.debug.assert(left_workspace);

        if (left_workspace) {
            handler.geometry.release(handler.geometry.context, detached.workspace);
        }
    }
};
