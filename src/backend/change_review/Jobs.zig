const Job = @import("Job.zig");
const ClientKey = @import("../history/ClientKey.zig");
const std = @import("std");
items: [4]?*Job = @splat(null),
storage: [4]Job = undefined,

pub fn available(self: *const @This(), client: ClientKey) !usize {
    var vacant: ?usize = null;
    for (self.items, 0..) |item, index| {
        if (item) |job| {
            if (job.client != null and std.meta.eql(job.client.?, client)) {
                return error.ReviewBusy;
            }
        } else if (vacant == null) {
            vacant = index;
        }
    }
    return vacant orelse error.ReviewBusy;
}

/// Leaves one worker slot available for user commands while replay discovery catches up.
/// Example: `const slot = jobs.discoverySlot() orelse return;`.
pub fn discoverySlot(self: *const @This()) ?usize {
    var vacant: ?usize = null;
    for (self.items, 0..) |item, index| {
        if (item == null) {
            if (vacant != null) {
                return vacant;
            }

            vacant = index;
        }
    }

    return null;
}

pub fn remove(self: *@This(), completed: *Job) void {
    for (&self.items) |*item| {
        if (item.* == completed) {
            item.* = null;
            return;
        }
    }
    unreachable;
}

pub fn deinitJoined(self: *@This()) void {
    for (&self.items) |*item| {
        if (item.*) |job| {
            job.deinit();
            item.* = null;
        }
    }
}
