const core = @import("telar-core");
const std = @import("std");
const TestAlive = @This();

keys: []const core.ImageKey,

pub fn holds(self: TestAlive, key: core.ImageKey) bool {
    for (self.keys) |candidate| if (std.meta.eql(candidate, key)) return true;
    return false;
}

pub fn holdsImage(self: TestAlive, image_id: u32) bool {
    for (self.keys) |candidate| if (candidate.image_id == image_id) return true;
    return false;
}
