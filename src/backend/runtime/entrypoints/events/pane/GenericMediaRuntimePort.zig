const Work = @import("MediaWork.zig");
const source_namespace = @import("media.zig");
const media_projection = @import("media_projection.zig");
/// Defines media actor startup and runtime-owned graphics projection effects.
///
/// ```zig
/// const port: RuntimePort(Context) = .{ ... };
/// ```
pub fn Type(comptime Context: type) type {
    return struct {
        start: *const fn (*Context, Work) anyerror!void,
        enforce_quotas: *const fn (*Context, *source_namespace.Pane) void,
        synchronize_clients: *const fn (*Context, *source_namespace.Pane, bool) media_projection.Stats,
        schedule_response: *const fn (*Context, *source_namespace.Pane) anyerror!void,
        pump_clients: *const fn (*Context) void,
        collect: *const fn (*Context) void,
    };
}
