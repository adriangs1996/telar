const source_namespace = @import("exit.zig");
/// Defines credential retirement, history scheduling, and runtime lifecycle
/// effects bound by the runtime instance.
///
/// ```zig
/// const port: RuntimePort(Context) = .{ ... };
/// ```
pub fn Type(comptime Context: type) type {
    return struct {
        revoke_credential: *const fn (*Context, *source_namespace.Pane) void,
        schedule_observation: *const fn (*Context, *source_namespace.Pane) anyerror!void,
        collect: *const fn (*Context) void,
        pump_clients: *const fn (*Context) void,
    };
}
