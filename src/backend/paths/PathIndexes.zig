//! The path indexes of the clients that opened a path picker: one per
//! client, a few at a time, each freed when its client leaves. A client
//! that finds every slot taken takes the one used longest ago that no
//! worker holds; its owner rebuilds it on its next request.

const core = @import("telar-core");
const std = @import("std");
const ClientKey = @import("../history/ClientKey.zig");
const PathIndex = @import("PathIndex.zig");
const PathIndexes = @This();

pub const capacity = 4;
pub const capacity_limit = core.Limit.declare("paths.indexes_capacity", "path indexes", capacity);

items: [capacity]?*PathIndex = @splat(null),
/// Counts requests, so `used_at` orders indexes by last use.
clock: u64 = 0,

/// Example: `const index = indexes.find(session.key) orelse return;`
pub fn find(self: *const PathIndexes, client: ClientKey) ?*PathIndex {
    for (self.items) |item| {
        const index = item orelse continue;
        if (std.meta.eql(index.client, client)) {
            return index;
        }
    }

    return null;
}

/// Reserves an index for `client`, freeing the idle one used longest ago
/// when every slot is taken; `error.PathPickerBusy` when workers hold them
/// all. Example: `const index = try indexes.add(model.gpa, session.key);`
pub fn add(self: *PathIndexes, gpa: std.mem.Allocator, client: ClientKey) !*PathIndex {
    const slot = self.freeSlot() orelse self.evictIdle() orelse return error.PathPickerBusy;
    const index = try PathIndex.create(gpa, client);
    self.items[slot] = index;
    self.touch(index);
    return index;
}

/// Marks `index` used by the request now being served. Example: `indexes.touch(index);`
pub fn touch(self: *PathIndexes, index: *PathIndex) void {
    self.clock += 1;
    index.used_at = self.clock;
}

fn freeSlot(self: *const PathIndexes) ?usize {
    for (self.items, 0..) |item, slot| {
        if (item == null) {
            return slot;
        }
    }

    return null;
}

// Frees the idle index used longest ago and returns its slot.
fn evictIdle(self: *PathIndexes) ?usize {
    var oldest: ?usize = null;
    for (self.items, 0..) |item, slot| {
        const index = item orelse continue;
        if (index.building or index.querying) {
            continue;
        }

        if (oldest == null or index.used_at < self.items[oldest.?].?.used_at) {
            oldest = slot;
        }
    }

    const slot = oldest orelse return null;
    self.items[slot].?.destroy();
    self.items[slot] = null;
    return slot;
}

/// Frees one index no worker holds. Example: `indexes.remove(index);`
pub fn remove(self: *PathIndexes, index: *PathIndex) void {
    std.debug.assert(!index.building and !index.querying);
    for (&self.items) |*item| {
        if (item.* == index) {
            item.* = null;
            index.destroy();
            return;
        }
    }

    unreachable;
}

/// Frees every index once the runtime's actors have joined.
pub fn deinitJoined(self: *PathIndexes) void {
    for (&self.items) |*item| {
        if (item.*) |index| {
            index.destroy();
            item.* = null;
        }
    }
}

test "one index per client within capacity" {
    var indexes: PathIndexes = .{};
    defer indexes.deinitJoined();

    const first = try indexes.add(
        std.testing.allocator,
        .{
            .id = 1,
            .generation = 1,
        },
    );
    try std.testing.expectEqual(first, indexes.find(.{
        .id = 1,
        .generation = 1,
    }).?);
    try std.testing.expectEqual(@as(?*PathIndex, null), indexes.find(.{
        .id = 1,
        .generation = 2,
    }));

    for (1..capacity) |client| {
        _ = try indexes.add(
            std.testing.allocator,
            .{
                .id = client + 1,
                .generation = 1,
            },
        );
    }

    // Every slot taken: the idle index used longest ago, the first, makes
    // room.
    const fifth = try indexes.add(
        std.testing.allocator,
        .{
            .id = 9,
            .generation = 1,
        },
    );
    try std.testing.expectEqual(@as(?*PathIndex, null), indexes.find(.{
        .id = 1,
        .generation = 1,
    }));

    // Only indexes a worker holds refuse a new client.
    for (indexes.items) |item| {
        item.?.building = true;
    }

    try std.testing.expectError(error.PathPickerBusy, indexes.add(
        std.testing.allocator,
        .{
            .id = 10,
            .generation = 1,
        },
    ));
    for (indexes.items) |item| {
        item.?.building = false;
    }

    indexes.remove(fifth);
    try std.testing.expectEqual(@as(?*PathIndex, null), indexes.find(.{
        .id = 9,
        .generation = 1,
    }));
}
