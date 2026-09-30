//! The Kitty graphics images the renderer holds as textures, one row per
//! handle (`row + 1`). Rows never move, so a handle names the same texture
//! from its upload until its release. Occupied rows are also kept in a dense
//! list, so every scan costs the textures held, not the table's capacity.
//! Only the window thread touches it.
const std = @import("std");
const client = @import("telar-client");
const core = @import("telar-core");
const ImageUpload = @import("../native/ImageUpload.zig");
const GpuImages = @This();

pub const capacity = ImageUpload.capacity;
/// Bytes the window's images may hold at once, pixels retained by every
/// machine's store and textures together: the client's global image quota.
pub const budget: usize = core.max_image_bytes_global;

const Row = u16;

pub const Residency = enum {
    free,
    /// The upload thread reads the image's pixels through `lease`.
    uploading,
    ready,
    /// The upload failed or the image cannot be a texture; nothing draws,
    /// and nothing retries until the image changes.
    failed,
    /// A released texture kept for an upload of the same size, still
    /// charged to the budget; the backend rewrites it in place.
    spare,
};

residency: [capacity]Residency = @splat(.free),
machine: [capacity]u8 = @splat(0),
identity: [capacity]client.ImageIdentity = undefined,
width: [capacity]u32 = @splat(0),
height: [capacity]u32 = @splat(0),
bytes: [capacity]usize = @splat(0),
lease: [capacity]client.retained_graphics.Lease = undefined,
/// When the upload was requested, on the window's monotonic clock.
started_ns: [capacity]u64 = @splat(0),
/// The frame that last drew the row, or that last needed it as a stand-in.
used_frame: [capacity]u64 = @splat(0),
/// When the row was last drawn, or became a spare.
used_ns: [capacity]u64 = @splat(0),
/// The row counted as a presented generation.
presented: [capacity]bool = @splat(false),
/// Occupied rows, densely; `position[row]` is the row's index here.
occupied: [capacity]Row = undefined,
position: [capacity]Row = undefined,
count: usize = 0,
/// Free rows, a stack.
free: [capacity]Row = initial_free,
free_count: usize = capacity,
resident_bytes: usize = 0,
uploading: usize = 0,
spares: usize = 0,

const initial_free: [capacity]Row = free: {
    var stack: [capacity]Row = undefined;
    for (&stack, 0..) |*row, index| {
        row.* = @intCast(capacity - 1 - index);
    }

    break :free stack;
};

/// The occupied rows. Example: `for (images.rows()) |row| { ... }`.
pub fn rows(self: *const GpuImages) []const Row {
    return self.occupied[0..self.count];
}

/// Takes a free row for `identity`. Example: `const row = images.add(slot, identity) orelse return;`.
pub fn add(self: *GpuImages, machine: u8, identity: client.ImageIdentity) ?usize {
    if (self.free_count == 0) {
        return null;
    }

    self.free_count -= 1;
    const row: usize = self.free[self.free_count];
    self.occupied[self.count] = @intCast(row);
    self.position[row] = @intCast(self.count);
    self.count += 1;
    self.assign(row, machine, identity);
    self.bytes[row] = 0;
    return row;
}

/// Gives a row a new image, keeping its texture and charged bytes.
/// Example: `images.assign(spare, slot, identity);`.
pub fn assign(self: *GpuImages, row: usize, machine: u8, identity: client.ImageIdentity) void {
    if (self.residency[row] == .spare) {
        self.spares -= 1;
    }

    self.residency[row] = .failed;
    self.machine[row] = machine;
    self.identity[row] = identity;
    self.used_frame[row] = 0;
    self.presented[row] = false;
}

/// Frees a row that holds no lease. Example: `images.remove(row);`.
pub fn remove(self: *GpuImages, row: usize) void {
    std.debug.assert(self.residency[row] != .free and self.residency[row] != .uploading);
    if (self.residency[row] == .spare) {
        self.spares -= 1;
    }

    self.resident_bytes -= self.bytes[row];
    self.residency[row] = .free;
    self.bytes[row] = 0;
    const index = self.position[row];
    self.count -= 1;
    const last = self.occupied[self.count];
    self.occupied[index] = last;
    self.position[last] = index;
    self.free[self.free_count] = @intCast(row);
    self.free_count += 1;
}

/// Example: `const row = images.find(slot, identity) orelse continue;`.
pub fn find(self: *const GpuImages, machine: u8, identity: client.ImageIdentity) ?usize {
    for (self.rows()) |row| {
        if (self.residency[row] != .spare and self.machine[row] == machine and std.meta.eql(self.identity[row], identity)) {
            return row;
        }
    }

    return null;
}

/// The ready row of the newest generation of the same logical image, in any
/// generation: the texture a placement draws while newer ones upload.
/// Example: `const row = images.findNewestReady(slot, identity);`.
pub fn findNewestReady(self: *const GpuImages, machine: u8, identity: client.ImageIdentity) ?usize {
    var best: ?usize = null;
    for (self.rows()) |row| {
        const other = self.identity[row];
        if (self.residency[row] != .ready or self.machine[row] != machine or other.pane_id != identity.pane_id or
            other.image_id != identity.image_id)
        {
            continue;
        }

        if (best == null or self.identity[best.?].generation < other.generation) {
            best = row;
        }
    }

    return best;
}

/// How many uploads of the same logical image are running.
/// Example: `if (images.uploadsOf(slot, identity) == limit) continue;`.
pub fn uploadsOf(self: *const GpuImages, machine: u8, identity: client.ImageIdentity) usize {
    if (self.uploading == 0) {
        return 0;
    }

    var uploads: usize = 0;
    for (self.rows()) |row| {
        const other = self.identity[row];
        if (self.residency[row] == .uploading and self.machine[row] == machine and other.pane_id == identity.pane_id and
            other.image_id == identity.image_id)
        {
            uploads += 1;
        }
    }

    return uploads;
}

/// A spare texture of exactly this size. Example: `const row = images.findSpare(width, height);`.
pub fn findSpare(self: *const GpuImages, width: u32, height: u32) ?usize {
    if (self.spares == 0) {
        return null;
    }

    for (self.rows()) |row| {
        if (self.residency[row] == .spare and self.width[row] == width and self.height[row] == height) {
            return row;
        }
    }

    return null;
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

test "rows stay put while the dense list follows adds and removes" {
    var images: GpuImages = .{};
    const identity: client.ImageIdentity = .{ .pane_id = @enumFromInt(1), .image_id = 1, .generation = 1 };
    const first = images.add(0, identity).?;
    const second = images.add(0, identity).?;
    const third = images.add(0, identity).?;
    images.remove(second);
    try std.testing.expectEqual(@as(usize, 2), images.count);
    try std.testing.expect(std.mem.indexOfScalar(Row, images.rows(), @intCast(first)) != null);
    try std.testing.expect(std.mem.indexOfScalar(Row, images.rows(), @intCast(third)) != null);
    try std.testing.expectEqual(second, images.add(0, identity).?);
}
