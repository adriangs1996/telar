//! Fixed curve cache. Entries and atlas texels are never overwritten while a
//! retained cell mesh can reference them. Full caches use seven reserved masks.
const Grid = @import("BoxGrid.zig");
const Slot = @import("GlyphSlot.zig");
const Entry = @import("BoxCacheEntry.zig");
const Cache = @This();

pub const capacity = 56;
pub const fallback_extent = [2]u32{ 16, 32 };
pub const raster_limit = 256;
entries: [capacity]Entry = @splat(.{}),
fallback: [7]Slot = undefined,
count: usize = 0,
rasterizations: usize = 0,

/// Reserves one exact shape/geometry identity; null means the fixed cache is full.
/// An entry without a slot remembers a failed admission, avoiding retries.
/// Example: `const entry = cache.entry(grid, shape) orelse return fallback;`
pub fn entry(self: *Cache, grid: Grid, shape: u3) ?*Entry {
    const key = (@as(u128, @as(u32, @bitCast(grid.width))) << 72) |
        (@as(u128, @as(u32, @bitCast(grid.height))) << 40) |
        (@as(u128, @as(u32, @bitCast(grid.light))) << 8) | @as(u128, shape + 1);
    for (self.entries[0..self.count]) |*stored| {
        if (stored.key == key) {
            return stored;
        }
    }

    if (self.count == capacity) {
        return null;
    }

    const stored = &self.entries[self.count];
    self.count += 1;
    stored.* = .{ .key = key, .pending = true };
    return stored;
}

test {
    _ = @import("box_atlas_test.zig");
}
