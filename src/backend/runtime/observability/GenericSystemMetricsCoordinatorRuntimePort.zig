const system_metrics = @import("system_metrics.zig");
/// Example: `const port: RuntimePort(Context) = .{ ... };`.
pub fn Type(comptime Context: type) type {
    return struct {
        rearm_tick: *const fn (*Context) anyerror!void,
        schedule: *const fn (*Context, system_metrics.Sampler) anyerror!void,
        pump_clients: *const fn (*Context) void,
    };
}
