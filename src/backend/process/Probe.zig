const Cache = @import("Cache.zig");
const Probe = @This();

cache: Cache,
/// Retry counters alone do not replace process evidence or invalidate its name.
changed: bool = false,
inspected: bool = false,
