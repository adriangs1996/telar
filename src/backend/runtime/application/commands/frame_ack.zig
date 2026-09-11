//! Application command for acknowledging one delivered pane frame.

const AttachmentStore = @import("../../attachment/AttachmentStore.zig");
const FrameAckHandler = @import("FrameAckHandler.zig");
const pane_module = @import("telar-core").pane;
const std = @import("std");

pub const FrameAckResult = union(enum) {
    acknowledged: u64,
    stale,
};

test "FrameAckHandler rejects an acknowledgement without an attachment" {
    var attachments: AttachmentStore = .{};
    var handler: FrameAckHandler = .{ .attachments = &attachments };

    const result = try handler.execute(.{
        .pane_id = try pane_module(7),
        .frame_id = 1,
        .received_at_ns = 50,
    });

    try std.testing.expectEqual(std.meta.Tag(FrameAckResult).stale, std.meta.activeTag(result));
}
