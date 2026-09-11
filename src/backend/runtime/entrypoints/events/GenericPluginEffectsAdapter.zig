const GenericPluginEffectsRuntimePort = @import("GenericPluginEffectsRuntimePort.zig").Type;
const PluginEffectsResources = @import("PluginEffectsResources.zig");
const Result = @import("../../../plugins/Result.zig");
const RecordCommandType = @import("../../../plugins/RecordCommand.zig");
const std = @import("std");
const AgentEvidenceType = @import("../../../plugins/AgentEvidence.zig");
const Status = @import("telar-core").Status;
const agent_identity = @import("../../application/coordinators/agent_identity.zig");
const NotificationType = @import("../../../plugins/Notification.zig");
const CoreNotification = @import("telar-core").Notification;
const encodeNotification_module = @import("telar-core").encodeNotification;

/// Binds tap authorization and effect application to one runtime application.
///
/// ```zig
/// const PluginEffectsAdapter = Adapter(Application, port);
/// ```
pub fn Type(comptime Context: type, comptime port: GenericPluginEffectsRuntimePort(Context)) type {
    return struct {
        const Self = @This();

        context: *Context,
        resources: PluginEffectsResources,

        /// Creates an adapter borrowing runtime-owned stores and worker service.
        ///
        /// ```zig
        /// const adapter = PluginEffectsAdapter.init(application, resources);
        /// ```
        pub fn init(context: *Context, resources: PluginEffectsResources) Self {
            return .{ .context = context, .resources = resources };
        }

        /// Rearms receive, validates worker identity and grants, then applies effects.
        ///
        /// ```zig
        /// try adapter.handle(result);
        /// ```
        pub fn handle(adapter: *Self, result_value: anyerror!*Result) !void {
            const result = result_value catch return;
            defer result.deinit();
            try port.rearm_receive(adapter.context);
            adapter.resources.service.authorize(result) catch return;

            var changed = false;
            for (result.batch.slice()) |effect| switch (effect) {
                .record_command => |record| adapter.recordCommand(result, record),
                .agent_evidence => |evidence| changed = adapter.applyAgentEvidence(evidence) or changed,
                .notification => |notification| {
                    if (adapter.publishNotification(notification)) {
                        changed = true;
                    }
                },
            };

            if (changed) {
                port.pump_clients(adapter.context);
            }
        }

        fn recordCommand(adapter: *Self, result: *const Result, record: RecordCommandType) void {
            const pane = adapter.resources.panes.resolve(.{ .id = result.pane, .generation = result.pane_generation }) orelse return;
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

        fn applyAgentEvidence(adapter: *Self, evidence: AgentEvidenceType) bool {
            const pane = adapter.resources.panes.find(evidence.pane) orelse return false;
            if (pane.exit != null) {
                return false;
            }
            const status: Status = switch (evidence.state) {
                .working, .settling => .working,
                .blocked => .blocked,
                .ready => .ready,
                .exited => return false,
            };

            return adapter.resources.agents.observeScreen(.{
                .identity = agent_identity.fromPane(pane),
                .signal = .{
                    .status = status,
                    .confidence = switch (evidence.confidence) {
                        .low => 40,
                        .medium => 70,
                    },
                    .identity_confirmed = true,
                    .ready_confirmed = status == .ready,
                },
                .observed_at_ms = port.now_ms(adapter.context),
            });
        }

        fn publishNotification(adapter: *Self, notification: NotificationType) bool {
            var validation_buffer: [512]u8 = undefined;
            const value: CoreNotification = .{
                .level = notification.level,
                .duration_ms = notification.duration_ms,
                .title = notification.title,
                .message = notification.message,
            };
            _ = encodeNotification_module(&validation_buffer, value) catch return false;
            return port.publish_notification(adapter.context, value) != 0;
        }
    };
}
