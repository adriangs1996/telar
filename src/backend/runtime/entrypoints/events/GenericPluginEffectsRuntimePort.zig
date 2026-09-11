const source_namespace = @import("plugin_effects.zig");
/// Defines runtime operations supplied by application composition.
///
/// ```zig
/// const port: RuntimePort(Application) = .{ .rearm_receive = rearm, .now_ms = now, .publish_notification = publish, .pump_clients = pump };
/// ```
pub fn Type(comptime Context: type) type {
    return struct {
        rearm_receive: *const fn (*Context) anyerror!void,
        now_ms: *const fn (*Context) i64,
        publish_notification: *const fn (*Context, source_namespace.schema.Notification) u8,
        pump_clients: *const fn (*Context) void,
    };
}
