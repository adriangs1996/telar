//! An authorized plugin returns typed effects for a captured exchange:
//! notifications, validated before publication.
const core = @import("telar-core");
const RuntimeModel = @import("RuntimeModel.zig");
const Sources = @import("Sources.zig");
const PluginNotification = @import("../plugins/Notification.zig");
const PluginResult = @import("../plugins/Result.zig");
const notifications = @import("notifications.zig");

/// Bytes enough to validate one plugin notification against its wire bound.
const notification_validation_bytes = 512;

/// Rearms the plugin receive, authorizes one effect batch and applies it.
///
/// ```zig
/// try proxy_tap.receive(model, result);
/// ```
pub fn receive(model: *RuntimeModel, result_value: anyerror!*PluginResult) !void {
    const result = result_value catch return;
    defer result.deinit();

    var sources = Sources.init(model.io, model.select);
    try sources.receivePluginEffects(model.resources.pluginService());
    model.resources.pluginService().authorize(result) catch return;

    for (result.batch.slice()) |effect| switch (effect) {
        .notification => |notification| _ = publishNotification(model, notification),
    };
}

fn publishNotification(model: *RuntimeModel, notification: PluginNotification) bool {
    var validation_buffer: [notification_validation_bytes]u8 = undefined;
    const value: core.Notification = .{
        .level = notification.level,
        .duration_ms = notification.duration_ms,
        .title = notification.title,
        .message = notification.message,
    };
    _ = core.encodeNotification(&validation_buffer, value) catch return false;
    return notifications.publish(model, value) != 0;
}
