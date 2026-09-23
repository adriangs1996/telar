const BarConfiguration = @import("../../bars/BarConfiguration.zig");
const DueInput = @This();

generation: u64,
configuration: *const BarConfiguration,
now_ns: u64,
