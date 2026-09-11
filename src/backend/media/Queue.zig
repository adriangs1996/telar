const Request = @import("Request.zig");
const Entry = @import("Entry.zig");
const transfer_preparation = @import("transfer_preparation.zig");
const Frozen = @import("Frozen.zig");
const PaneMediaAllocatorType = @import("PaneMediaAllocator.zig");
const Queue = @This();

pub const Input = @import("Request.zig");

entries: [8]?Entry = @splat(null),

/// Offers one deduplicated request without retaining emulator pointers.
/// Example: `const added = queue.request(request);`.
pub fn request(queue: *Queue, value: Request) bool {
    var free: ?usize = null;
    for (queue.entries, 0..) |entry, index| {
        if (entry) |existing| {
            if (transfer_preparation.same(existing.request, value)) {
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
        if (!transfer_preparation.same(entry.request, value)) {
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
pub fn process(queue: *Queue, storage: anytype, media: *PaneMediaAllocatorType) void {
    for (&queue.entries) |*slot| {
        const entry = if (slot.*) |*entry| entry else continue;
        const image = storage.imageById(entry.request.key.image_id) orelse {
            transfer_preparation.discardEntry(slot, media);
            continue;
        };
        if (image.generation != entry.request.key.generation) {
            transfer_preparation.discardEntry(slot, media);
            continue;
        }
        if (entry.result != null) {
            continue;
        }

        const pixels = media.imagePixels(image.data.bytes()) orelse {
            entry.result = error.ImageUnavailable;
            continue;
        };
        entry.result = transfer_preparation.freeze(entry.request, pixels, media);
    }
}

/// Releases parked results after joining the actor, including detach cleanup.
/// Example: `queue.deinit(media_allocator);`.
pub fn deinit(queue: *Queue, media: *PaneMediaAllocatorType) void {
    for (&queue.entries) |*slot| {
        transfer_preparation.discardEntry(slot, media);
    }
}

/// Releases work no remaining consumer needs, including detach and reset.
/// Example: `queue.retain(consumers, media_allocator);`.
pub fn retain(queue: *Queue, consumers: anytype, media: *PaneMediaAllocatorType) void {
    for (&queue.entries) |*slot| {
        const entry = slot.* orelse continue;
        if (!consumers.wants(entry.request.key, entry.request.shared_transport)) {
            transfer_preparation.discardEntry(slot, media);
        }
    }
}
