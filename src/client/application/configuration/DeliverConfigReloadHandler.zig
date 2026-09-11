const ModelType = @import("../../model/Model.zig");
const ConfigReloadDeliveryEffects = @import("ConfigReloadDeliveryEffects.zig");
const config_reload_delivery = @import("config_reload_delivery.zig");
const DiagnosticType = @import("../../config/Diagnostic.zig");
const ClientDiagnosticHandlerType = @import("ClientDiagnosticHandler.zig");
const client_diagnostic = @import("client_diagnostic.zig");
const std = @import("std");
const DeliverConfigReloadHandler = @This();

model: *ModelType,
effects: ConfigReloadDeliveryEffects,

/// Delivers one resolved reload and rearms its watcher only after every
/// outcome-specific effect has succeeded.
///
/// ```zig
/// const outcome = try handler.execute(resolution);
/// ```
pub fn execute(handler: *DeliverConfigReloadHandler, resolution: config_reload_delivery.Resolution) !config_reload_delivery.Outcome {
    const outcome: config_reload_delivery.Outcome = switch (resolution) {
        .unchanged => .unchanged,
        .rejected => |diagnostic| try handler.deliverRejection(diagnostic),
        .adopted => try handler.deliverAdoption(),
    };

    try handler.effects.rearm(handler.effects.context);

    return outcome;
}

fn deliverRejection(handler: *DeliverConfigReloadHandler, diagnostic: DiagnosticType) !config_reload_delivery.Outcome {
    var diagnostic_handler: ClientDiagnosticHandlerType = .{ .model = handler.model };
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

fn deliverAdoption(handler: *DeliverConfigReloadHandler) !config_reload_delivery.Outcome {
    const commit = try handler.effects.apply_adoption(handler.effects.context);
    try handler.effects.publish_notification(handler.effects.context, .{
        .level = .success,
        .title = "Configuration reloaded",
        .message = "The new settings are active",
    });

    return .{ .adopted = commit };
}
