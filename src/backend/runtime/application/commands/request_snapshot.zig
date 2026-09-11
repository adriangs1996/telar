//! Application command for resynchronizing one client's pane projection.

const AttachmentStore = @import("../../attachment/AttachmentStore.zig");
const RequestCellSnapshotHandler = @import("RequestCellSnapshotHandler.zig");
const pane_module = @import("telar-core").pane;
const std = @import("std");

pub const RequestCellSnapshotResult = enum {
    requested,
    pane_not_attached,
};

test "RequestCellSnapshotHandler rejects a pane outside the client attachments" {
    var attachments: AttachmentStore = .{};
    var handler: RequestCellSnapshotHandler = .{ .attachments = &attachments };

    const result = try handler.execute(.{ .pane_id = try pane_module(7) });

    try std.testing.expectEqual(RequestCellSnapshotResult.pane_not_attached, result);
}
