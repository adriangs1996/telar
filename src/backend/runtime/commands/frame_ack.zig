//! Application command for acknowledging one delivered pane frame.

const std = @import("std");
const core = @import("telar-core");
const attachment_mod = @import("../attachment.zig");

const schema = core.schema;
const AttachmentStore = attachment_mod.AttachmentStore;

pub const AcknowledgeFrame = struct {
    pane_id: schema.PaneId,
    frame_id: u64,
    received_at_ns: u64,
};

pub const FrameAckResult = union(enum) {
    acknowledged: u64,
    stale,
};

pub const FrameAckHandler = struct {
    attachments: *AttachmentStore,

    /// Releases the exact outstanding frame for one client attachment and
    /// returns its delivery latency. Missing, older, future, and duplicate
    /// acknowledgements are stale and leave synchronization state unchanged.
    ///
    /// ```zig
    /// const result = try handler.execute(acknowledgement);
    /// ```
    pub fn execute(handler: *FrameAckHandler, command: AcknowledgeFrame) !FrameAckResult {
        const elapsed = handler.attachments.acknowledgeFrame(.{
            .pane_id = command.pane_id,
            .frame_id = command.frame_id,
        }, command.received_at_ns) orelse return .stale;

        return .{ .acknowledged = elapsed };
    }
};

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
