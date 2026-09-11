/// One frozen generation waiting for a client attachment to adopt it.
const PreparedTransfer = @This();
const core = @import("telar-core");
const source_namespace = @import("shared_transfer.zig");
const std = @import("std");
metadata: core.graphics.Image,
name: core.graphics.ShmName,
/// Bytes reserved against the pane budget for the object's lifetime.
reserved_len: usize,

pub fn discard(transfer: PreparedTransfer, media: *source_namespace.PaneMediaAllocator) void {
    _ = std.c.shm_unlink(transfer.name.sliceZ());
    media.releaseManual(transfer.reserved_len);
}
