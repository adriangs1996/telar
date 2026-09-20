const Job = @import("Job.zig");
const ClientKey = @import("../history/ClientKey.zig");
const std = @import("std");
items: [4]?*Job = @splat(null),
storage: [4]Job = undefined,

pub fn available(self: *const @This(), client: ClientKey) !usize {
    var vacant: ?usize = null;
    for (self.items, 0..) |item, index| {
        if (item) |job| {
            if (std.meta.eql(job.client, client)) {
                return error.ReviewBusy;
            }
        } else if (vacant == null) {
            vacant = index;
        }
    }
    return vacant orelse error.ReviewBusy;
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
