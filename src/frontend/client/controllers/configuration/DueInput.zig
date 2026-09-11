const DueInput = @This();
const bars = @import("../../../bars/root.zig");
generation: u64,
configuration: *const bars.Configuration,
now_ns: u64,
