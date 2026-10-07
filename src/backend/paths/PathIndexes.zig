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
