//! Application command for rebuilding one client's graphics projection.

const AttachmentStore = @import("../../attachment/AttachmentStore.zig");
const RequestGraphicsSnapshotHandler = @import("RequestGraphicsSnapshotHandler.zig");
const pane_module = @import("telar-core").pane;
const std = @import("std");

pub const RequestGraphicsSnapshotResult = enum {
    requested,
    pane_not_attached,
};

test "RequestGraphicsSnapshotHandler rejects a pane outside the client attachments" {
    var attachments: AttachmentStore = .{};
    var handler: RequestGraphicsSnapshotHandler = .{ .attachments = &attachments };

    const result = try handler.execute(.{ .pane_id = try pane_module(7) });

    try std.testing.expectEqual(RequestGraphicsSnapshotResult.pane_not_attached, result);
}
