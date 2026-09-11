const Work = @import("ObservationWork.zig");
const source_namespace = @import("observation.zig");
/// Defines observation actor startup and runtime-owned projection effects.
///
/// ```zig
/// const port: RuntimePort(Context) = .{ ... };
/// ```
pub fn Type(comptime Context: type) type {
    return struct {
        start: *const fn (*Context, Work) anyerror!void,
        publish_sound: *const fn (*Context, source_namespace.schema.AgentSoundNotification) void,
        schedule_description: *const fn (*Context) void,
        collect: *const fn (*Context) void,
        pump_clients: *const fn (*Context) void,
    };
}
