//! Application command for rebuilding one client's graphics projection.

const std = @import("std");
const core = @import("telar-core");
const attachment_mod = @import("../../attachment/root.zig");

const schema = core.schema;
const AttachmentStore = attachment_mod.AttachmentStore;

pub const RequestGraphicsSnapshot = struct {
    pane_id: schema.PaneId,
};

pub const RequestGraphicsSnapshotResult = enum {
    requested,
    pane_not_attached,
};

pub const RequestGraphicsSnapshotHandler = struct {
    attachments: *AttachmentStore,

    /// Discards one attachment's graphics baseline and schedules a complete
    /// replacement. Repeated requests coalesce into the same pending snapshot.
    ///
    /// ```zig
    /// const result = try handler.execute(.{ .pane_id = pane_id });
    /// ```
    pub fn execute(handler: *RequestGraphicsSnapshotHandler, command: RequestGraphicsSnapshot) !RequestGraphicsSnapshotResult {
        if (!handler.attachments.requestGraphicsSnapshot(command.pane_id)) {
            return .pane_not_attached;
        }

        return .requested;
    }
};

test "RequestGraphicsSnapshotHandler rejects a pane outside the client attachments" {
    var attachments: AttachmentStore = .{};
    var handler: RequestGraphicsSnapshotHandler = .{ .attachments = &attachments };

    const result = try handler.execute(.{ .pane_id = try schema.id.pane(7) });

    try std.testing.expectEqual(RequestGraphicsSnapshotResult.pane_not_attached, result);
}
