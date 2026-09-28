//! The path indexes of the clients that opened a path picker: one per
//! client, a few at a time, each freed when its client leaves.

const std = @import("std");
const ClientKey = @import("../history/ClientKey.zig");
const PathIndex = @import("PathIndex.zig");
const PathIndexes = @This();

pub const capacity = 4;

items: [capacity]?*PathIndex = @splat(null),

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

/// Reserves an index for `client`; `error.PathPickerBusy` when every slot is taken.
/// Example: `const index = try indexes.add(model.gpa, session.key);`
pub fn add(self: *PathIndexes, gpa: std.mem.Allocator, client: ClientKey) !*PathIndex {
    for (&self.items) |*item| {
        if (item.* != null) {
            continue;
        }

        const index = try PathIndex.create(gpa, client);
        item.* = index;
        return index;
    }

    return error.PathPickerBusy;
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

    try std.testing.expectError(error.PathPickerBusy, indexes.add(
        std.testing.allocator,
        .{
            .id = 9,
            .generation = 1,
        },
    ));
    indexes.remove(first);
    try std.testing.expectEqual(@as(?*PathIndex, null), indexes.find(.{
        .id = 1,
        .generation = 1,
    }));
}
