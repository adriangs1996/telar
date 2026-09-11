const CommandType = @import("../../../agent/Command.zig");
const JobType = @import("../../../agent/Job.zig");
const DescriptionFinishedType = @import("../../../agent/DescriptionFinished.zig");

/// Defines generator startup, durable title projection, and client delivery
/// bound by the runtime instance.
///
/// ```zig
/// const port: RuntimePort(Context) = .{ ... };
/// ```
pub fn Type(comptime Context: type) type {
    return struct {
        start: *const fn (*Context, CommandType, JobType) anyerror!void,
        persist: *const fn (*Context, DescriptionFinishedType) void,
        pump_clients: *const fn (*Context) void,
    };
}
