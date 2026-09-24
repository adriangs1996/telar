//! An authorized plugin returns typed effects for a captured exchange:
//! command history, agent evidence or notifications, validated before use.
const agent_status = @import("agent_status.zig");

const core = @import("telar-core");
const std = @import("std");
const RuntimeModel = @import("RuntimeModel.zig");
const Sources = @import("Sources.zig");
const AgentEvidence = @import("../plugins/AgentEvidence.zig");
const PluginNotification = @import("../plugins/Notification.zig");
const PluginResult = @import("../plugins/Result.zig");
const RecordCommand = @import("../plugins/RecordCommand.zig");
const agent_identity = @import("agent_identity.zig");
const notifications = @import("notifications.zig");

/// Confidence that plugin evidence carries, by the plugin's own grade.
const EvidenceConfidence = enum(u8) {
    low = 40,
    medium = 70,
};

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
        .record_command => |record| recordCommand(model, result, record),
        .agent_evidence => |evidence| _ = observeEvidence(model, evidence),
        .notification => |notification| _ = publishNotification(model, notification),
    };
}

fn recordCommand(model: *RuntimeModel, result: *const PluginResult, record: RecordCommand) void {
    const pane = model.panes.resolve(.{ .id = result.pane, .generation = result.pane_generation }) orelse return;
    if (pane.exit != null) {
        return;
    }

    const duration = std.math.cast(i64, record.duration_ms) orelse std.math.maxInt(i64);
    _ = pane.recordAgentCommand(.{
        .command = .{
            .bytes = record.command,
            .cwd = record.cwd,
            .started_at_ms = record.started_at_ms,
            .duration_ns = duration *| std.time.ns_per_ms,
            .exit_code = record.exit_code,
            .status = .completed,
            .truncated = false,
        },
        .provider = record.provider,
        .tool_call_id = record.tool_call_id,
        .origin = .plugin,
        .redact = record.redact,
    });
}

fn observeEvidence(model: *RuntimeModel, evidence: AgentEvidence) bool {
    const pane = model.panes.find(evidence.pane) orelse return false;
    if (pane.exit != null) {
        return false;
    }

    const status: core.Status = switch (evidence.state) {
        .working, .settling => .working,
        .blocked => .blocked,
        .ready => .ready,
        .exited => return false,
    };

    return agent_status.observeScreen(model, .{
        .identity = agent_identity.fromPane(pane),
        .signal = .{
            .status = status,
            .confidence = @intFromEnum(switch (evidence.confidence) {
                .low => EvidenceConfidence.low,
                .medium => EvidenceConfidence.medium,
            }),
            .identity_confirmed = true,
            .ready_confirmed = status == .ready,
        },
        .observed_at_ms = std.Io.Timestamp.now(model.io, .real).toMilliseconds(),
    });
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
