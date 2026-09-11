const ObservationWork = @import("ObservationWork.zig");
const AgentSoundNotificationType = @import("telar-core").AgentSoundNotification;

/// Defines observation actor startup and runtime-owned projection effects.
///
/// ```zig
/// const port: RuntimePort(Context) = .{ ... };
/// ```
pub fn Type(comptime Context: type) type {
    return struct {
        start: *const fn (*Context, ObservationWork) anyerror!void,
        publish_sound: *const fn (*Context, AgentSoundNotificationType) void,
        schedule_description: *const fn (*Context) void,
        collect: *const fn (*Context) void,
        pump_clients: *const fn (*Context) void,
    };
}
