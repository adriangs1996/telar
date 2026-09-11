const GraphicsBudget = @This();
const ParkingMutex = @import("ParkingMutex.zig");
const PaneMediaAllocator = @import("PaneMediaAllocator.zig");
const std = @import("std");
mutex: ParkingMutex = .{},
limit: usize,
used: usize = 0,

pub fn init(limit: usize) GraphicsBudget {
    return .{ .limit = limit };
}

pub fn reserve(budget: *GraphicsBudget, pane: *PaneMediaAllocator, bytes: usize) bool {
    budget.mutex.lock();
    defer budget.mutex.unlock();
    const pane_next = std.math.add(usize, pane.used, bytes) catch return false;
    const global_next = std.math.add(usize, budget.used, bytes) catch return false;
    if (pane_next > pane.limit or global_next > budget.limit) {
        return false;
    }
    pane.used = pane_next;
    budget.used = global_next;
    return true;
}

pub fn release(budget: *GraphicsBudget, pane: *PaneMediaAllocator, bytes: usize) void {
    budget.mutex.lock();
    defer budget.mutex.unlock();
    std.debug.assert(bytes <= pane.used and bytes <= budget.used);
    pane.used -= bytes;
    budget.used -= bytes;
}

pub fn releaseAll(budget: *GraphicsBudget, pane: *PaneMediaAllocator) void {
    budget.mutex.lock();
    defer budget.mutex.unlock();
    std.debug.assert(pane.used <= budget.used);
    budget.used -= pane.used;
    pane.used = 0;
}
