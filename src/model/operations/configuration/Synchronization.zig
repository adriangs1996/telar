const BarConfiguration = @import("../../bars/BarConfiguration.zig");
const Synchronization = @This();

generation: u64,
configuration: ?*const BarConfiguration,
now_ns: u64,
