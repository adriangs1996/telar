const Liveness = @This();
const identity = @import("../identity.zig");
context: *anyopaque,
is_live: *const fn (*anyopaque, *const identity.Credential) bool,
