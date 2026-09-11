const source_namespace = @import("telemetry_tick_coordinator.zig");
/// Defines sink availability, sampling, and actor scheduling bound by the
/// runtime instance. `format_sample` must return a slice backed by its
/// buffer argument; the write actor owns that storage until completion.
///
/// ```zig
/// const port: RuntimePort(Context) = .{ ... };
/// ```
pub fn Type(comptime Context: type) type {
    return struct {
        available: *const fn (*Context, *const source_namespace.State) bool,
        disable: *const fn (*Context, *source_namespace.State) void,
        schedule_tick: *const fn (*Context) anyerror!void,
        format_sample: *const fn (*Context, []u8) anyerror![]const u8,
        schedule_write: *const fn (*Context, *source_namespace.State, []const u8) anyerror!void,
    };
}
