const ConfigurationType = @import("telar-client").Configuration;
const DueInput = @This();

generation: u64,
configuration: *const ConfigurationType,
now_ns: u64,
