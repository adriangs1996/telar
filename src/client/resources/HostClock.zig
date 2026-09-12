const LocalTimeType = @import("LocalTime.zig");
/// Wall-clock reads the client needs for chrome such as the bar clock.
const HostClock = @This();

context: *anyopaque,
local_time_fn: *const fn (*anyopaque) LocalTimeType,

/// Example: `const local = client.clock.localTime();`.
pub fn localTime(port: HostClock) LocalTimeType {
    return port.local_time_fn(port.context);
}
