const Probe = @This();
const Cache = @import("Cache.zig");
cache: Cache,
changed: bool = false,
inspected: bool = false,
