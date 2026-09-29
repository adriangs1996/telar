//! The Kitty graphics images the renderer holds as textures, one row per
//! handle (`row + 1`). Rows never move, so a handle names the same texture
//! from its upload until its release. Only the window thread touches it.
const std = @import("std");
const client = @import("telar-client");
const core = @import("telar-core");
const ImageUpload = @import("../native/ImageUpload.zig");
const GpuImages = @This();

pub const capacity = ImageUpload.capacity;
/// GPU bytes all images may hold at once: the client's global image quota,
/// so the window never holds more texture memory than the runtime may send.
pub const budget: usize = core.max_image_bytes_global;

pub const Residency = enum {
    free,
    /// The upload thread reads the image's pixels through `lease`.
    uploading,
    ready,
    /// The upload failed or the image cannot be a texture; nothing draws,
    /// and nothing retries until the image changes.
    failed,
};

residency: [capacity]Residency = @splat(.free),
machine: [capacity]u8 = @splat(0),
identity: [capacity]client.ImageIdentity = undefined,
width: [capacity]u32 = @splat(0),
height: [capacity]u32 = @splat(0),
bytes: [capacity]usize = @splat(0),
lease: [capacity]client.retained_graphics.Lease = undefined,
/// The frame that last drew the row, or that last needed it as a stand-in.
used_frame: [capacity]u64 = @splat(0),
count: usize = 0,
resident_bytes: usize = 0,
uploading: usize = 0,

/// Takes a free row for `identity`. Example: `const row = images.add(slot, identity) orelse return;`.
pub fn add(self: *GpuImages, machine: u8, identity: client.ImageIdentity) ?usize {
    for (self.residency, 0..) |residency, row| {
        if (residency != .free) {
            continue;
        }

        self.residency[row] = .failed;
        self.machine[row] = machine;
        self.identity[row] = identity;
        self.width[row] = 0;
        self.height[row] = 0;
        self.bytes[row] = 0;
        self.used_frame[row] = 0;
        self.count += 1;
        return row;
    }

    return null;
}

/// Frees a row that holds no lease. Example: `images.remove(row);`.
pub fn remove(self: *GpuImages, row: usize) void {
    std.debug.assert(self.residency[row] != .free and self.residency[row] != .uploading);
    self.resident_bytes -= self.bytes[row];
    self.residency[row] = .free;
    self.bytes[row] = 0;
    self.count -= 1;
}

/// Example: `const row = images.find(slot, identity) orelse continue;`.
pub fn find(self: *const GpuImages, machine: u8, identity: client.ImageIdentity) ?usize {
    if (self.count == 0) {
        return null;
    }

    for (self.residency, 0..) |residency, row| {
        if (residency != .free and self.machine[row] == machine and std.meta.eql(self.identity[row], identity)) {
            return row;
        }
    }

    return null;
}

/// A ready row of the same logical image in another generation, the one
/// that keeps drawing while its replacement uploads.
/// Example: `const stand_in = images.findStandIn(slot, identity);`.
pub fn findStandIn(self: *const GpuImages, machine: u8, identity: client.ImageIdentity) ?usize {
    if (self.count == 0) {
        return null;
    }

    var best: ?usize = null;
    for (self.residency, 0..) |residency, row| {
        const other = self.identity[row];
        if (residency != .ready or self.machine[row] != machine or other.pane_id != identity.pane_id or
            other.image_id != identity.image_id or other.generation == identity.generation)
        {
            continue;
        }

        if (best == null or self.identity[best.?].generation < other.generation) {
            best = row;
        }
    }

    return best;
}

/// Whether an upload of the same logical image is already running.
/// Example: `if (images.uploadingImage(slot, identity)) continue;`.
pub fn uploadingImage(self: *const GpuImages, machine: u8, identity: client.ImageIdentity) bool {
    if (self.uploading == 0) {
        return false;
    }

    for (self.residency, 0..) |residency, row| {
        const other = self.identity[row];
        if (residency == .uploading and self.machine[row] == machine and other.pane_id == identity.pane_id and
            other.image_id == identity.image_id)
        {
            return true;
        }
    }

    return false;
}

/// Example: `const handle = GpuImages.handleOf(row);`.
pub fn handleOf(slot: usize) u32 {
    return @intCast(slot + 1);
}

/// Example: `const row = GpuImages.rowOf(handle) orelse return;`.
pub fn rowOf(handle: u32) ?usize {
    if (handle == 0 or handle > capacity) {
        return null;
    }

    return handle - 1;
}
