const ConfigurationType = @import("../../bars/BarConfiguration.zig");
const Synchronization = @This();

generation: u64,
configuration: ?*const ConfigurationType,
now_ns: u64,
