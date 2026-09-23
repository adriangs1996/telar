const ParkingMutex = @import("ParkingMutex.zig");
const PaneMediaAllocator = @import("PaneMediaAllocator.zig");
const std = @import("std");
const GraphicsBudget = @This();

mutex: ParkingMutex = .{},
limit: usize,
used: usize = 0,

pub fn init(limit: usize) GraphicsBudget {
    return .{ .limit = limit };
}

pub fn reserve(self: *GraphicsBudget, pane: *PaneMediaAllocator, bytes: usize) bool {
    self.mutex.lock();
    defer self.mutex.unlock();
    const pane_next = std.math.add(usize, pane.used, bytes) catch return false;
    const global_next = std.math.add(usize, self.used, bytes) catch return false;
    if (pane_next > pane.limit or global_next > self.limit) {
        return false;
    }
    pane.used = pane_next;
    self.used = global_next;
    return true;
}

pub fn release(self: *GraphicsBudget, pane: *PaneMediaAllocator, bytes: usize) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    std.debug.assert(bytes <= pane.used and bytes <= self.used);
    pane.used -= bytes;
    self.used -= bytes;
}

pub fn releaseAll(self: *GraphicsBudget, pane: *PaneMediaAllocator) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    std.debug.assert(pane.used <= self.used);
    self.used -= pane.used;
    pane.used = 0;
}
