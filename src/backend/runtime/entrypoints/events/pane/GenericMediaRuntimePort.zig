const MediaWork = @import("MediaWork.zig");
const PaneType = @import("../../../../pane/Pane.zig");
const StatsType = @import("Stats.zig");

/// Defines media actor startup and runtime-owned graphics projection effects.
///
/// ```zig
/// const port: RuntimePort(Context) = .{ ... };
/// ```
pub fn Type(comptime Context: type) type {
    return struct {
        start: *const fn (*Context, MediaWork) anyerror!void,
        enforce_quotas: *const fn (*Context, *PaneType) void,
        synchronize_clients: *const fn (*Context, *PaneType, bool) StatsType,
        schedule_response: *const fn (*Context, *PaneType) anyerror!void,
        pump_clients: *const fn (*Context) void,
        collect: *const fn (*Context) void,
    };
}
