const Clock = @import("Clock.zig");
const Observation = @This();

bytes: []const u8,
clock: Clock,
