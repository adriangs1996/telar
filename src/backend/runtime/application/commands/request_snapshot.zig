//! Application command for resynchronizing one client's pane projection.

const std = @import("std");
const core = @import("telar-core");
const attachment_mod = @import("../../attachment/root.zig");

const schema = core.schema;
const AttachmentStore = attachment_mod.AttachmentStore;

pub const RequestCellSnapshot = struct {
    pane_id: schema.PaneId,
};

pub const RequestCellSnapshotResult = enum {
    requested,
    pane_not_attached,
};

pub const RequestCellSnapshotHandler = struct {
    attachments: *AttachmentStore,

    /// Marks one attached pane for an unconditional full cell snapshot. The
    /// attachment coalesces repeated requests until delivery consumes the mark.
    ///
    /// ```zig
    /// const result = try handler.execute(.{ .pane_id = pane_id });
    /// ```
    pub fn execute(handler: *RequestCellSnapshotHandler, command: RequestCellSnapshot) !RequestCellSnapshotResult {
        if (!handler.attachments.requestCellSnapshot(command.pane_id)) {
            return .pane_not_attached;
        }

        return .requested;
    }
};

test "RequestCellSnapshotHandler rejects a pane outside the client attachments" {
    var attachments: AttachmentStore = .{};
    var handler: RequestCellSnapshotHandler = .{ .attachments = &attachments };

    const result = try handler.execute(.{ .pane_id = try schema.id.pane(7) });

    try std.testing.expectEqual(RequestCellSnapshotResult.pane_not_attached, result);
}
