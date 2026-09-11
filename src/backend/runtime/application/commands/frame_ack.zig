//! Application command for acknowledging one delivered pane frame.

const std = @import("std");
const core = @import("telar-core");
const attachment_mod = @import("../../attachment/root.zig");

pub const schema = core.schema;
pub const AttachmentStore = attachment_mod.AttachmentStore;

pub const AcknowledgeFrame = @import("AcknowledgeFrame.zig");

pub const FrameAckResult = union(enum) {
    acknowledged: u64,
    stale,
};

pub const FrameAckHandler = @import("FrameAckHandler.zig");

test "FrameAckHandler rejects an acknowledgement without an attachment" {
    var attachments: AttachmentStore = .{};
    var handler: FrameAckHandler = .{ .attachments = &attachments };

    const result = try handler.execute(.{
        .pane_id = try schema.id.pane(7),
        .frame_id = 1,
        .received_at_ns = 50,
    });

    try std.testing.expectEqual(std.meta.Tag(FrameAckResult).stale, std.meta.activeTag(result));
}
