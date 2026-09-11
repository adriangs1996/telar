const Cache = @import("Cache.zig");
const Probe = @This();

cache: Cache,
changed: bool = false,
inspected: bool = false,
