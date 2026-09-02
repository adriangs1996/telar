//! Runtime-event adapters that mutate the agent aggregate.

const std = @import("std");
const agent_mod = @import("../../../agent/root.zig");
const engine = @import("../../../engine/root.zig");
const pane_mod = @import("../../../pane/root.zig");
const proxy_mod = @import("../../../proxy/root.zig");
const runtime_event_entrypoints = @import("../../entrypoints/events/root.zig");
const event_sources = @import("../../event_sources.zig");
const coordinators = @import("../coordinators/root.zig");

const Io = std.Io;

const agent_description_coordinator = coordinators.agent_description;
const agent_maintenance_coordinator = coordinators.agent_maintenance;
const proxy_observation_adapter = runtime_event_entrypoints.proxy_observation;

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
            checkEngineIdle(application);
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

        /// Applies one engine reply and rearms the engine receive. Title
        /// replies enter the description coordinator like a one-shot result.
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
                .title => |title| handleDescription(application, describeFromEngine(title, &response)),
            }
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

        fn describeFromEngine(title: engine.Purpose.Title, response: *const engine.Response) agent_mod.description.Result {
            const pane: pane_mod.PaneKey = .{ .id = @enumFromInt(title.pane_id), .generation = title.pane_generation };
            return switch (response.status) {
                .success => agent_mod.description.resultFromReply(pane, title.session_id, response.textSlice()),
                .unavailable, .timeout, .invalid_output, .failed => |status| .{
                    .pane = pane,
                    .session_id = title.session_id,
                    .status = switch (status) {
                        .unavailable => .unavailable,
                        .timeout => .timeout,
                        .invalid_output => .invalid_output,
                        else => .failed,
                    },
                },
            };
        }

        /// The generator the coordinator may start: the engine when one is
        /// configured, otherwise the one-shot description command.
        fn agentDescriptionCoordinator(application: *Application) RuntimeAgentDescriptionCoordinator {
            const command: ?agent_mod.description.Command = if (application.engine_options) |options|
                .{ .arguments = options.arguments, .timeout_ms = options.timeout_ms }
            else if (application.agent_description_options) |options|
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

            if (application.engine_service) |service| {
                return startEngineDescription(application, service, &job);
            }

            try application.select.concurrent(
                .agent_description,
                agent_mod.description.generate,
                .{ application.io, application.gpa, .{ .command = command, .job = job } },
            );
        }

        fn startEngineDescription(application: *Application, service: *engine.Service, job: *const agent_mod.description.Job) !void {
            var prompt_buffer: [agent_mod.description.max_title_prompt_bytes]u8 = undefined;
            defer std.crypto.secureZero(u8, &prompt_buffer);
            const purpose: engine.Purpose = .{ .title = .{
                .pane_id = @intFromEnum(job.pane.id),
                .pane_generation = job.pane.generation,
                .session_id = job.session_id,
            } };
            var request: engine.Request = .{ .prompt = try engine.Prompt.init(purpose, agent_mod.description.titlePrompt(job, &prompt_buffer)) };
            defer std.crypto.secureZero(u8, &request.prompt.bytes);

            if (!service.submit(application.io, request)) {
                return error.EngineBusy;
            }
        }

        fn persistAgentDescription(application: *Application, finished: agent_mod.DescriptionFinished) void {
            _ = application.history_service.setSessionTitle(application.io, .{
                .id = finished.session_id,
                .title = finished.titleSlice(),
                .source = finished.source,
                .state = finished.state,
            });
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

        fn pumpRuntimeClients(application: *Application) void {
            application.pumpAll();
        }
    };
}

test {
    std.testing.refAllDecls(@This());
}
