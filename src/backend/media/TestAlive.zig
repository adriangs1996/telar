const ImageKeyType = @import("telar-core").ImageKey;
const std = @import("std");
const TestAlive = @This();

keys: []const ImageKeyType,

pub fn holds(alive: TestAlive, key: ImageKeyType) bool {
    for (alive.keys) |candidate| if (std.meta.eql(candidate, key)) return true;
    return false;
}

pub fn holdsImage(alive: TestAlive, image_id: u32) bool {
    for (alive.keys) |candidate| if (candidate.image_id == image_id) return true;
    return false;
}
