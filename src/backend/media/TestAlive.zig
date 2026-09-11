const TestAlive = @This();
const core = @import("telar-core");
const std = @import("std");
keys: []const core.graphics.ImageKey,

pub fn holds(alive: TestAlive, key: core.graphics.ImageKey) bool {
    for (alive.keys) |candidate| if (std.meta.eql(candidate, key)) return true;
    return false;
}

pub fn holdsImage(alive: TestAlive, image_id: u32) bool {
    for (alive.keys) |candidate| if (candidate.image_id == image_id) return true;
    return false;
}
