const core = @import("telar-core");
const std = @import("std");
const TestAlive = @This();

keys: []const core.ImageKey,

pub fn holds(alive: TestAlive, key: core.ImageKey) bool {
    for (alive.keys) |candidate| if (std.meta.eql(candidate, key)) return true;
    return false;
}

pub fn holdsImage(alive: TestAlive, image_id: u32) bool {
    for (alive.keys) |candidate| if (candidate.image_id == image_id) return true;
    return false;
}
