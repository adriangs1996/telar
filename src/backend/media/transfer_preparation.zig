//! Bounded transfer requests executed only while the media actor owns storage.

const Entry = @import("Entry.zig");
const PaneMediaAllocatorType = @import("PaneMediaAllocator.zig");
const std = @import("std");
const Request = @import("Request.zig");
const Frozen = @import("Frozen.zig");
const shared = @import("shared_transfer.zig");

pub fn discardEntry(slot: *?Entry, media: *PaneMediaAllocatorType) void {
    const entry = slot.* orelse return;
    if (entry.result) |result| {
        if (result) |frozen| {
            entry.request.allocator.free(frozen.pixels);
            if (frozen.name) |name| {
                _ = std.c.shm_unlink(name.sliceZ());
            }

            media.releaseManual(frozen.reserved_len);
        } else |_| {}
    }

    slot.* = null;
}

pub fn same(a: Request, b: Request) bool {
    return std.meta.eql(a.key, b.key) and a.shared_transport == b.shared_transport and
        a.allocator.ptr == b.allocator.ptr and a.allocator.vtable == b.allocator.vtable;
}

pub fn freeze(request: Request, pixels: []const u8, media: *PaneMediaAllocatorType) !Frozen {
    if (!media.reserveManual(pixels.len)) {
        return error.GraphicsQuotaExceeded;
    }
    errdefer media.releaseManual(pixels.len);

    if (request.shared_transport) {
        if (shared.freezeSharedPixels(pixels)) |name| {
            return .{ .name = name, .reserved_len = pixels.len };
        }
    }

    return .{ .pixels = try request.allocator.dupe(u8, pixels), .reserved_len = pixels.len };
}
