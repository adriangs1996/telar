const BarConfiguration = @import("../../bars/BarConfiguration.zig");

generation: u64,
configuration: ?*const BarConfiguration,
now_ns: u64,
