//! Runtime boundary for authorized effects returned by tap workers.

const std = @import("std");
const core = @import("telar-core");
const agent_mod = @import("../../../agent/root.zig");
const pane_mod = @import("../../../pane/root.zig");
const plugins = @import("../../../plugins/root.zig");

const schema = core.schema;

pub const Resources = struct {
    panes: *pane_mod.PaneStore,
    agents: *agent_mod.Tracker,
    service: *plugins.Service,
};

/// Defines runtime operations supplied by application composition.
///
/// ```zig
/// const port: RuntimePort(Application) = .{ .rearm_receive = rearm, .now_ms = now, .publish_notification = publish, .pump_clients = pump };
/// ```
pub fn RuntimePort(comptime Context: type) type {
    return struct {
        rearm_receive: *const fn (*Context) anyerror!void,
        now_ms: *const fn (*Context) i64,
        publish_notification: *const fn (*Context, schema.Notification) u8,
        pump_clients: *const fn (*Context) void,
    };
}

/// Binds tap authorization and effect application to one runtime application.
///
/// ```zig
/// const PluginEffectsAdapter = Adapter(Application, port);
/// ```
pub fn Adapter(comptime Context: type, comptime port: RuntimePort(Context)) type {
    return struct {
        const Self = @This();

        context: *Context,
        resources: Resources,

        /// Creates an adapter borrowing runtime-owned stores and worker service.
        ///
        /// ```zig
        /// const adapter = PluginEffectsAdapter.init(application, resources);
        /// ```
        pub fn init(context: *Context, resources: Resources) Self {
            return .{ .context = context, .resources = resources };
        }

        /// Rearms receive, validates worker identity and grants, then applies effects.
        ///
        /// ```zig
        /// try adapter.handle(result);
        /// ```
        pub fn handle(adapter: *Self, result_value: anyerror!*plugins.EffectResult) !void {
            const result = result_value catch return;
            defer result.deinit();
            try port.rearm_receive(adapter.context);
            adapter.resources.service.authorize(result) catch return;

            var changed = false;
            for (result.batch.slice()) |effect| switch (effect) {
                .record_command => {},
                .agent_evidence => |evidence| changed = adapter.applyAgentEvidence(evidence) or changed,
                .notification => |notification| {
                    if (adapter.publishNotification(notification)) changed = true;
                },
            };

            if (changed) port.pump_clients(adapter.context);
        }

        fn applyAgentEvidence(adapter: *Self, evidence: plugins.effects.AgentEvidence) bool {
            const pane = adapter.resources.panes.find(evidence.pane) orelse return false;
            if (pane.exit != null) return false;
            const status: agent_mod.ScreenStatus = switch (evidence.state) {
                .working => .working,
                .blocked => .blocked,
                .ready => .ready,
                .exited => return false,
            };

            return adapter.resources.agents.observeScreen(.{
                .identity = agent_mod.Identity.fromPane(pane),
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

        fn publishNotification(adapter: *Self, notification: plugins.effects.Notification) bool {
            var validation_buffer: [512]u8 = undefined;
            const value: schema.Notification = .{
                .level = notification.level,
                .duration_ms = notification.duration_ms,
                .title = notification.title,
                .message = notification.message,
            };
            _ = schema.encodeNotification(&validation_buffer, value) catch return false;
            return port.publish_notification(adapter.context, value) != 0;
        }
    };
}

test {
    std.testing.refAllDecls(@This());
}
