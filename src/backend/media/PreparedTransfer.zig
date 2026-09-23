const core = @import("telar-core");
const PaneMediaAllocator = @import("PaneMediaAllocator.zig");
const std = @import("std");
/// One frozen generation waiting for a client attachment to adopt it.
const PreparedTransfer = @This();

metadata: core.Image,
name: core.ShmName,
/// Bytes reserved against the pane budget for the object's lifetime.
reserved_len: usize,

pub fn discard(transfer: PreparedTransfer, media: *PaneMediaAllocator) void {
    _ = std.c.shm_unlink(transfer.name.sliceZ());
    media.releaseManual(transfer.reserved_len);
}
