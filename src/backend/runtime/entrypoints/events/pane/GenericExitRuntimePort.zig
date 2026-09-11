const PaneType = @import("../../../../pane/Pane.zig");

/// Defines credential retirement, history scheduling, and runtime lifecycle
/// effects bound by the runtime instance.
///
/// ```zig
/// const port: RuntimePort(Context) = .{ ... };
/// ```
pub fn Type(comptime Context: type) type {
    return struct {
        revoke_credential: *const fn (*Context, *PaneType) void,
        schedule_observation: *const fn (*Context, *PaneType) anyerror!void,
        collect: *const fn (*Context) void,
        pump_clients: *const fn (*Context) void,
    };
}
