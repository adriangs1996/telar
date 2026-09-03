//! Runtime-event adapters that mutate the agent aggregate.

const std = @import("std");
const agent_mod = @import("../../../agent/root.zig");
const engine = @import("../../../engine/root.zig");
const proxy_mod = @import("../../../proxy/root.zig");
const plugins = @import("../../../plugins/root.zig");
const delivery_mod = @import("../../delivery/root.zig");
const suggestion = @import("../suggestion.zig");
const runtime_event_entrypoints = @import("../../entrypoints/events/root.zig");
const event_sources = @import("../../event_sources.zig");
const coordinators = @import("../coordinators/root.zig");

const Io = std.Io;

const agent_description_coordinator = coordinators.agent_description;
const agent_maintenance_coordinator = coordinators.agent_maintenance;
const proxy_observation_adapter = runtime_event_entrypoints.proxy_observation;
const proxy_capture_adapter = runtime_event_entrypoints.proxy_capture;
const plugin_effects_adapter = runtime_event_entrypoints.plugin_effects;

/// Binds agent-related event completions to one concrete Application type.
///
/// ```zig
/// const AgentEvents = Dispatcher(Application);
/// ```
pub fn Dispatcher(comptime Application: type) type {
    return struct {
        /// Applies one proxy observation to its agent and rearms proxy receive.
        ///
        /// ```zig
        /// try AgentEvents.handleProxyObservation(&application, result);
        /// ```
        pub fn handleProxyObservation(application: *Application, result: anyerror!proxy_mod.Observation) !void {
            var adapter = proxyObservationAdapter(application);
            try adapter.handle(result);
        }

        pub fn handleProxyCapture(application: *Application, result: anyerror!*proxy_mod.CaptureHalf) !void {
            var adapter = proxyCaptureAdapter(application);
            try adapter.handle(result);
        }

        /// Authorizes and applies one bounded effect batch, then rearms receive.
        ///
        /// ```zig
        /// try AgentEvents.handlePluginEffects(&application, result);
        /// ```
        pub fn handlePluginEffects(application: *Application, result: anyerror!*plugins.EffectResult) !void {
            var adapter = pluginEffectsAdapter(application);
            try adapter.handle(result);
        }

        /// Applies one maintenance tick, expires stale agent activity and
        /// rearms the periodic source.
        ///
        /// ```zig
        /// try AgentEvents.handleMaintenance(&application, result);
        /// ```
        pub fn handleMaintenance(application: *Application, result: anyerror!void) !void {
            var coordinator = agentMaintenanceCoordinator(application);
            try coordinator.handle(result);
            try application.flushSessionCheckpoint();
            application.tickGitStatus();
            application.tickSessionNames();
            checkEngineIdle(application);
            application.proxy_runtime.expireCaptures(runtimeWallClockMs(application));
        }

        /// Applies one generated description and persists the resulting title.
        ///
        /// ```zig
        /// AgentEvents.handleDescription(&application, result);
        /// ```
        pub fn handleDescription(application: *Application, result: agent_mod.description.Result) void {
            var coordinator = agentDescriptionCoordinator(application);
            coordinator.handle(result);
        }

        /// Starts the next queued agent-description job when the configured
        /// generator and coordinator state permit it.
        ///
        /// ```zig
        /// AgentEvents.scheduleDescription(&application);
        /// ```
        pub fn scheduleDescription(application: *Application) void {
            var coordinator = agentDescriptionCoordinator(application);
            _ = coordinator.schedule();
        }

        const agent_description_runtime_port: agent_description_coordinator.RuntimePort(Application) = .{
            .start = startAgentDescription,
            .persist = persistAgentDescription,
            .pump_clients = pumpRuntimeClients,
        };

        const RuntimeAgentDescriptionCoordinator = agent_description_coordinator.Coordinator(Application, agent_description_runtime_port);

        /// Applies one engine reply and rearms the engine receive.
        ///
        /// ```zig
        /// try AgentEvents.handleEngineResponse(&application, result);
        /// ```
        pub fn handleEngineResponse(application: *Application, result: anyerror!engine.Response) !void {
            const response = result catch return;
            const service = application.engine_service orelse return;
            var sources = event_sources.Sources.init(application.io, application.select);
            try sources.receiveEngine(service);

            switch (response.purpose) {
                .suggestion => |target| deliverSuggestion(application, target, &response),
            }
        }

        /// Answers the client that asked for a suggestion, if it is still
        /// connected; a departed client simply drops the reply.
        fn deliverSuggestion(application: *Application, target: engine.Purpose.Suggestion, response: *const engine.Response) void {
            const session = application.clients.resolve(.{ .id = target.client_id, .generation = target.client_generation }) orelse return;
            var pending: delivery_mod.PendingSuggestion = .{
                .request_id = @enumFromInt(target.request_id),
                .status = switch (response.status) {
                    .success => .ready,
                    .unavailable => .unavailable,
                    .timeout => .timeout,
                    .invalid_output, .failed => .failed,
                },
            };
            if (pending.status == .ready) {
                if (suggestion.extractCommand(response.textSlice())) |command| {
                    @memcpy(pending.text[0..command.len], command);
                    pending.text_len = @intCast(command.len);
                } else {
                    pending.status = .failed;
                }
            }

            session.delivery.responses.push(.{ .command_suggestion = pending }) catch return;
            application.pumpAll();
        }

        /// Asks the engine to kill its child when it has been idle. Called
        /// from the agent maintenance tick; it queues nothing when no child
        /// is alive.
        ///
        /// ```zig
        /// AgentEvents.checkEngineIdle(&application);
        /// ```
        pub fn checkEngineIdle(application: *Application) void {
            const service = application.engine_service orelse return;
            service.requestIdleCheck(application.io);
        }

        fn agentDescriptionCoordinator(application: *Application) RuntimeAgentDescriptionCoordinator {
            const command: ?agent_mod.description.Command = if (application.agent_description_options) |options|
                .{ .arguments = options.arguments, .timeout_ms = options.timeout_ms }
            else
                null;

            return RuntimeAgentDescriptionCoordinator.init(application, .{
                .agents = &application.model.agents,
                .state = &application.agent_description_state,
                .command = command,
            });
        }

        fn startAgentDescription(application: *Application, command: agent_mod.description.Command, job_value: agent_mod.description.Job) !void {
            var job = job_value;
            defer std.crypto.secureZero(u8, &job.query);

            try application.select.concurrent(
                .agent_description,
                agent_mod.description.generate,
                .{ application.io, application.gpa, .{ .command = command, .job = job } },
            );
        }

        fn persistAgentDescription(application: *Application, finished: agent_mod.DescriptionFinished) void {
            _ = application.history_service.setSessionTitle(application.io, .{
                .id = finished.session_id,
                .title = finished.titleSlice(),
                .source = finished.source,
                .state = finished.state,
            });

            if (finished.state == .ready) {
                application.noteSessionChange();
            }
        }

        const agent_maintenance_runtime_port: agent_maintenance_coordinator.RuntimePort(Application) = .{
            .rearm_tick = rearmAgentMaintenance,
            .now_ms = runtimeWallClockMs,
            .pump_clients = pumpRuntimeClients,
        };

        const RuntimeAgentMaintenanceCoordinator = agent_maintenance_coordinator.Coordinator(Application, agent_maintenance_runtime_port);

        fn agentMaintenanceCoordinator(application: *Application) RuntimeAgentMaintenanceCoordinator {
            return RuntimeAgentMaintenanceCoordinator.init(application, .{ .agents = &application.model.agents });
        }

        fn rearmAgentMaintenance(application: *Application) !void {
            var sources = event_sources.Sources.init(application.io, application.select);
            try sources.waitForAgentMaintenance();
        }

        fn runtimeWallClockMs(application: *Application) i64 {
            return Io.Timestamp.now(application.io, .real).toMilliseconds();
        }

        const proxy_observation_runtime_port: proxy_observation_adapter.RuntimePort(Application) = .{
            .rearm_receive = rearmProxyObservation,
            .schedule_description = scheduleDescription,
            .pump_clients = pumpRuntimeClients,
        };

        const RuntimeProxyObservationAdapter = proxy_observation_adapter.Adapter(Application, proxy_observation_runtime_port);

        fn proxyObservationAdapter(application: *Application) RuntimeProxyObservationAdapter {
            return RuntimeProxyObservationAdapter.init(application, .{
                .panes = &application.model.panes,
                .agents = &application.model.agents,
                .metrics = &application.metrics,
            });
        }

        fn rearmProxyObservation(application: *Application) !void {
            var sources = event_sources.Sources.init(application.io, application.select);
            try sources.receiveProxyObservation(application.proxy_runtime);
        }

        const proxy_capture_runtime_port: proxy_capture_adapter.RuntimePort(Application) = .{
            .rearm_receive = rearmProxyCapture,
            .now_ms = runtimeWallClockMs,
        };

        const RuntimeProxyCaptureAdapter = proxy_capture_adapter.Adapter(Application, proxy_capture_runtime_port);

        fn proxyCaptureAdapter(application: *Application) RuntimeProxyCaptureAdapter {
            return RuntimeProxyCaptureAdapter.init(application, .{
                .panes = &application.model.panes,
                .proxy_runtime = application.proxy_runtime,
            });
        }

        fn rearmProxyCapture(application: *Application) !void {
            var sources = event_sources.Sources.init(application.io, application.select);
            try sources.receiveProxyCapture(application.proxy_runtime);
        }

        const plugin_effects_runtime_port: plugin_effects_adapter.RuntimePort(Application) = .{
            .rearm_receive = rearmPluginEffects,
            .now_ms = runtimeWallClockMs,
            .publish_notification = publishPluginNotification,
            .pump_clients = pumpRuntimeClients,
        };

        const RuntimePluginEffectsAdapter = plugin_effects_adapter.Adapter(Application, plugin_effects_runtime_port);

        fn pluginEffectsAdapter(application: *Application) RuntimePluginEffectsAdapter {
            return RuntimePluginEffectsAdapter.init(application, .{
                .panes = &application.model.panes,
                .agents = &application.model.agents,
                .service = application.plugin_service,
                .history_service = application.history_service,
            });
        }

        fn rearmPluginEffects(application: *Application) !void {
            var sources = event_sources.Sources.init(application.io, application.select);
            try sources.receivePluginEffects(application.plugin_service);
        }

        fn publishPluginNotification(application: *Application, notification: @import("telar-core").schema.Notification) u8 {
            return application.publishNotification(notification);
        }

        fn pumpRuntimeClients(application: *Application) void {
            application.pumpAll();
        }
    };
}

test {
    std.testing.refAllDecls(@This());
}
