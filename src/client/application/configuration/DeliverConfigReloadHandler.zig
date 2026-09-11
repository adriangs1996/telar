const DeliverConfigReloadHandler = @This();
const client_model = @import("../../root.zig").model;
const Effects = @import("ConfigReloadDeliveryEffects.zig");
const source_namespace = @import("config_reload_delivery.zig");
const lua_config = @import("../../config/root.zig");
const client_diagnostic = @import("client_diagnostic.zig");
const std = @import("std");
model: *client_model.Model,
effects: Effects,

/// Delivers one resolved reload and rearms its watcher only after every
/// outcome-specific effect has succeeded.
///
/// ```zig
/// const outcome = try handler.execute(resolution);
/// ```
pub fn execute(handler: *DeliverConfigReloadHandler, resolution: source_namespace.Resolution) !source_namespace.Outcome {
    const outcome: source_namespace.Outcome = switch (resolution) {
        .unchanged => .unchanged,
        .rejected => |diagnostic| try handler.deliverRejection(diagnostic),
        .adopted => try handler.deliverAdoption(),
    };

    try handler.effects.rearm(handler.effects.context);

    return outcome;
}

fn deliverRejection(handler: *DeliverConfigReloadHandler, diagnostic: lua_config.Diagnostic) !source_namespace.Outcome {
    var diagnostic_handler: client_diagnostic.ClientDiagnosticHandler = .{ .model = handler.model };
    _ = try diagnostic_handler.replace(.{
        .diagnostic = diagnostic,
        .invalid_fallback = client_diagnostic.formatted(
            "configuration reload failed: invalid diagnostic text",
            .{},
        ),
    });
    const message = handler.model.diagnostic() orelse return error.ClientDiagnosticMissing;
    try handler.effects.publish_notification(handler.effects.context, .{
        .level = .failure,
        .title = "Configuration rejected",
        .message = message,
        .duration_ns = 7 * std.time.ns_per_s,
    });

    return .rejected;
}

fn deliverAdoption(handler: *DeliverConfigReloadHandler) !source_namespace.Outcome {
    const commit = try handler.effects.apply_adoption(handler.effects.context);
    try handler.effects.publish_notification(handler.effects.context, .{
        .level = .success,
        .title = "Configuration reloaded",
        .message = "The new settings are active",
    });

    return .{ .adopted = commit };
}
