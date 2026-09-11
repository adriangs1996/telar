//! Application command for rebuilding one client's graphics projection.

const std = @import("std");
const core = @import("telar-core");
const attachment_mod = @import("../../attachment/root.zig");

pub const schema = core.schema;
pub const AttachmentStore = attachment_mod.AttachmentStore;

pub const RequestGraphicsSnapshot = @import("RequestGraphicsSnapshot.zig");

pub const RequestGraphicsSnapshotResult = enum {
    requested,
    pane_not_attached,
};

pub const RequestGraphicsSnapshotHandler = @import("RequestGraphicsSnapshotHandler.zig");

test "RequestGraphicsSnapshotHandler rejects a pane outside the client attachments" {
    var attachments: AttachmentStore = .{};
    var handler: RequestGraphicsSnapshotHandler = .{ .attachments = &attachments };

    const result = try handler.execute(.{ .pane_id = try schema.id.pane(7) });

    try std.testing.expectEqual(RequestGraphicsSnapshotResult.pane_not_attached, result);
}
