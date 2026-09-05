//! Bounded transfer requests executed only while the media actor owns storage.
const std = @import("std");
const core = @import("telar-core");
const allocation = @import("allocator.zig");
const shared = @import("shared_transfer.zig");

pub const Request = struct {
    key: core.graphics.ImageKey,
    shared_transport: bool,
    allocator: std.mem.Allocator,
};

pub const Frozen = struct {
    pixels: []u8 = &.{},
    name: ?core.graphics.ShmName = null,
    reserved_len: usize,
};

const Entry = struct {
    request: Request,
    result: ?anyerror!Frozen = null,
};

pub const Queue = struct {
    pub const Input = Request;

    entries: [8]?Entry = @splat(null),

    /// Offers one deduplicated request without retaining emulator pointers.
    /// Example: `const added = queue.request(request);`.
    pub fn request(queue: *Queue, value: Request) bool {
        var free: ?usize = null;
        for (queue.entries, 0..) |entry, index| {
            if (entry) |existing| {
                if (same(existing.request, value)) {
                    return false;
                }
            } else if (free == null) {
                free = index;
            }
        }

        const index = free orelse return false;
        queue.entries[index] = .{ .request = value };
        return true;
    }

    /// Transfers one completed reservation to the attachment. Null means pending.
    /// Example: `const frozen = try queue.take(request) orelse return;`.
    pub fn take(queue: *Queue, value: Request) !?Frozen {
        for (&queue.entries) |*slot| {
            const entry = slot.* orelse continue;
            if (!same(entry.request, value)) {
                continue;
            }

            const result = entry.result orelse return null;
            slot.* = null;
            return try result;
        }

        return null;
    }

    /// Freezes requests against the media actor's current immutable read borrow.
    /// Example: `queue.process(storage, media_allocator);`.
    pub fn process(queue: *Queue, storage: anytype, media: *allocation.PaneMediaAllocator) void {
        for (&queue.entries) |*slot| {
            const entry = if (slot.*) |*entry| entry else continue;
            const image = storage.imageById(entry.request.key.image_id) orelse {
                discardEntry(slot, media);
                continue;
            };
            if (image.generation != entry.request.key.generation) {
                discardEntry(slot, media);
                continue;
            }
            if (entry.result != null) {
                continue;
            }

            const pixels = media.imagePixels(image.data.bytes()) orelse {
                entry.result = error.ImageUnavailable;
                continue;
            };
            entry.result = freeze(entry.request, pixels, media);
        }
    }

    /// Releases parked results after joining the actor, including detach cleanup.
    /// Example: `queue.deinit(media_allocator);`.
    pub fn deinit(queue: *Queue, media: *allocation.PaneMediaAllocator) void {
        for (&queue.entries) |*slot| {
            discardEntry(slot, media);
        }
    }

    /// Releases work no remaining consumer needs, including detach and reset.
    /// Example: `queue.retain(consumers, media_allocator);`.
    pub fn retain(queue: *Queue, consumers: anytype, media: *allocation.PaneMediaAllocator) void {
        for (&queue.entries) |*slot| {
            const entry = slot.* orelse continue;
            if (!consumers.wants(entry.request.key, entry.request.shared_transport)) {
                discardEntry(slot, media);
            }
        }
    }
};

fn discardEntry(slot: *?Entry, media: *allocation.PaneMediaAllocator) void {
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

fn same(a: Request, b: Request) bool {
    return std.meta.eql(a.key, b.key) and a.shared_transport == b.shared_transport and
        a.allocator.ptr == b.allocator.ptr and a.allocator.vtable == b.allocator.vtable;
}

fn freeze(request: Request, pixels: []const u8, media: *allocation.PaneMediaAllocator) !Frozen {
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
