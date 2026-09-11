//! Application command for resynchronizing one client's pane projection.

const std = @import("std");
const core = @import("telar-core");
const attachment_mod = @import("../../attachment/root.zig");

pub const schema = core.schema;
pub const AttachmentStore = attachment_mod.AttachmentStore;

pub const RequestCellSnapshot = @import("RequestCellSnapshot.zig");

pub const RequestCellSnapshotResult = enum {
    requested,
    pane_not_attached,
};

pub const RequestCellSnapshotHandler = @import("RequestCellSnapshotHandler.zig");

test "RequestCellSnapshotHandler rejects a pane outside the client attachments" {
    var attachments: AttachmentStore = .{};
    var handler: RequestCellSnapshotHandler = .{ .attachments = &attachments };

    const result = try handler.execute(.{ .pane_id = try schema.id.pane(7) });

    try std.testing.expectEqual(RequestCellSnapshotResult.pane_not_attached, result);
}
