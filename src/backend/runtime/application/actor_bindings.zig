//! Adapters between application state and asynchronous runtime actors.

const std = @import("std");
const core = @import("telar-core");
const agent_process = @import("../../process/root.zig");
const history = @import("../../history/root.zig");
const event_entrypoints = @import("../entrypoints/events/root.zig");
const attachment_mod = @import("../attachment/root.zig");
const client_runtime = @import("../client/root.zig");
const client_session = client_runtime.session;
const client_store = client_runtime.store;
const runtime_config = @import("../config.zig");
const runtime_event = @import("../event.zig");
const agent_event_dispatcher = @import("event_dispatcher/agent.zig");
const client_event_dispatcher = @import("event_dispatcher/client.zig");
const history_event_dispatcher = @import("event_dispatcher/history.zig");
const observability_event_dispatcher = @import("event_dispatcher/observability.zig");
const pane_io_event_dispatcher = @import("event_dispatcher/pane/io.zig");
const request_dispatch = @import("request_dispatch.zig");
const pane_events = event_entrypoints.pane;
const media_projection = pane_events.media_projection;
const pane_launcher_mod = @import("pane_launcher.zig");
const pane_exit_coordinator = pane_events.exit;
const pane_ingest_coordinator = pane_events.ingest;
const pane_media_coordinator = pane_events.media;
const pane_observation_coordinator = pane_events.observation;
const pane_output_pipeline = pane_events.output;
const pane_mod = @import("../../pane/root.zig");
const media_mod = @import("../../media/root.zig");
const observability = @import("../observability/root.zig");
const telemetry_mod = observability.telemetry;
const transport = @import("../../transport/root.zig");

const schema = core.schema;
const diagnostics = core.diagnostics;

const Pane = pane_mod.Pane;
const AttachmentStore = attachment_mod.AttachmentStore;
const enforceGraphicsQuotas = attachment_mod.enforceGraphicsQuotas;
const TelemetryState = telemetry_mod.State;
const max_clients = client_store.max_clients;

const IngestTestGate = runtime_config.IngestTestGate;
const RuntimeEvent = runtime_event.Event;
const PaneIngestEvent = pane_ingest_coordinator.Completion;
const PaneObservationEvent = pane_observation_coordinator.Completion;
const PaneMediaEvent = pane_media_coordinator.Completion;
const ClientSession = client_session.Session;

/// Builds the zero-allocation actor bindings for one application type.
///
/// ```zig
/// const Actors = Bindings(Application);
/// ```
pub fn Bindings(comptime Application: type) type {
    const AgentEvents = agent_event_dispatcher.Dispatcher(Application);
    const ClientEvents = client_event_dispatcher.Dispatcher(Application);
    const HistoryEvents = history_event_dispatcher.Dispatcher(Application);
    const ObservabilityEvents = observability_event_dispatcher.Dispatcher(Application);
    const PaneIoEvents = pane_io_event_dispatcher.Dispatcher(Application);

    return struct {
        pub const EventResources = struct {
            listener: *transport.local.LocalListener,
            telemetry: *TelemetryState,
            ingest_gate: ?*IngestTestGate,
        };

        /// Routes one non-stop runtime event through its actor coordinator.
        ///
        /// ```zig
        /// const should_stop = try Actors.handle(&application, event, resources);
        /// ```
        pub fn handle(application: *Application, event: RuntimeEvent, resources: EventResources) !bool {
            switch (event) {
                .stopped => unreachable,
                .accepted => |result| {
                    try ClientEvents.handleAccepted(application, result, resources.listener);
                },
                .handshaken => |result| {
                    ClientEvents.handleHandshaken(application, result);
                },
                .client_message => |value| return ClientEvents.handleMessage(application, value),
                .client_sent => |value| return ClientEvents.handleSent(application, value),
                .history_response => |result| {
                    try HistoryEvents.handle(application, result);
                },
                .proxy_event => |result| {
                    try AgentEvents.handleProxyObservation(application, result);
                },
                .agent_tick => |result| {
                    try AgentEvents.handleMaintenance(application, result);
                },
                .agent_description => |result| {
                    AgentEvents.handleDescription(application, result);
                },
                .metrics_tick => |result| {
                    try ObservabilityEvents.handleMetricsTick(application, result);
                },
                .pane_input_written => |value| {
                    try PaneIoEvents.handleInputWritten(application, value);
                },
                .pane_response_written => |value| {
                    try PaneIoEvents.handleResponseWritten(application, value);
                },
                .pane_output => |value| {
                    var context: PaneOutputRuntime = .{ .application = application, .ingest_gate = resources.ingest_gate };
                    var pipeline = paneOutputPipeline(&context);
                    try pipeline.handle(value);
                },
                .pane_ingested => |value| {
                    var coordinator = paneIngestCoordinator(application);
                    try coordinator.handle(value);
                },
                .pane_observed => |value| {
                    var coordinator = paneObservationCoordinator(application);
                    try coordinator.handle(value);
                },
                .pane_media => |value| {
                    var coordinator = paneMediaCoordinator(application);
                    try coordinator.handle(value);
                },
                .pane_exit => |value| {
                    var coordinator = paneExitCoordinator(application);
                    try coordinator.handle(value);
                },
                .telemetry_tick => |result| {
                    ObservabilityEvents.handleTelemetryTick(application, resources.telemetry, result);
                },
                .telemetry_written => |result| {
                    ObservabilityEvents.handleTelemetryWritten(application, resources.telemetry, result);
                },
            }

            return false;
        }

        /// Schedules a bounded client write after delivery prepared its payload.
        ///
        /// ```zig
        /// try Actors.startSessionSend(&application, session, payload);
        /// ```
        pub fn startSessionSend(application: *Application, session: *ClientSession, payload: []const u8) !void {
            return ClientEvents.startSend(application, session, payload);
        }

        fn collectPaneLifecycle(application: *Application) void {
            application.collect();
        }

        const PaneOutputRuntime = struct {
            application: *Application,
            ingest_gate: ?*IngestTestGate,
        };

        const pane_output_runtime_port: pane_output_pipeline.RuntimePort(PaneOutputRuntime) = .{
            .schedule_observation = scheduleOutputObservation,
            .schedule_media = scheduleOutputMedia,
            .start_ingest = startOutputIngest,
            .has_outstanding_frame = paneHasOutstandingFrame,
            .collect = collectAfterOutput,
            .pump_clients = pumpAfterOutput,
        };

        const RuntimePaneOutputPipeline = pane_output_pipeline.Pipeline(PaneOutputRuntime, pane_output_runtime_port);

        fn paneOutputPipeline(context: *PaneOutputRuntime) RuntimePaneOutputPipeline {
            return RuntimePaneOutputPipeline.init(context, .{
                .io = context.application.io,
                .panes = &context.application.model.panes,
                .metrics = &context.application.metrics,
            });
        }

        fn scheduleOutputObservation(context: *PaneOutputRuntime, pane: *Pane) !void {
            return schedulePaneObservation(context.application, pane);
        }

        fn scheduleOutputMedia(context: *PaneOutputRuntime, pane: *Pane) !void {
            return schedulePaneMedia(context.application, pane);
        }

        const PaneIngestTask = struct {
            ingest: pane_output_pipeline.Ingest,
            gate: ?*IngestTestGate,
        };

        fn startOutputIngest(context: *PaneOutputRuntime, ingest: pane_output_pipeline.Ingest) !void {
            try context.application.select.concurrent(.pane_ingested, ingestPane, .{PaneIngestTask{
                .ingest = ingest,
                .gate = context.ingest_gate,
            }});
        }

        fn paneHasOutstandingFrame(context: *PaneOutputRuntime, pane_id: schema.PaneId) bool {
            for (&context.application.clients.items) |*slot| {
                const client = slot.* orelse continue;
                const attachment = client.attachments.find(pane_id) orelse continue;

                if (attachment.outstandingFrameId() != 0) {
                    return true;
                }
            }

            return false;
        }

        fn collectAfterOutput(context: *PaneOutputRuntime) void {
            context.application.collect();
        }

        fn pumpAfterOutput(context: *PaneOutputRuntime) void {
            context.application.pumpAll();
        }

        fn ingestPane(task: PaneIngestTask) PaneIngestEvent {
            const path = diagnostics.enter(.interactive);
            defer path.restore();

            if (task.gate) |gate| {
                gate.wait(task.ingest.io) catch |err| {
                    return .{ .pane = task.ingest.pane.key(), .result = err };
                };
            }

            var stats: pane_ingest_coordinator.Stats = .{};
            stats.elapsed_ns = task.ingest.pane.ingest(task.ingest.io, task.ingest.bytes) catch |err| {
                return .{ .pane = task.ingest.pane.key(), .result = err };
            };

            return .{ .pane = task.ingest.pane.key(), .result = stats };
        }

        const pane_ingest_runtime_port: pane_ingest_coordinator.RuntimePort(Application) = .{
            .schedule_observation = scheduleIngestObservation,
            .schedule_media = scheduleIngestMedia,
            .refresh_clients = refreshPaneClients,
            .schedule_response = PaneIoEvents.scheduleResponse,
            .start_read = startNextPaneRead,
            .collect = collectPaneLifecycle,
            .pump_clients = pumpRuntimeClients,
        };

        const RuntimePaneIngestCoordinator = pane_ingest_coordinator.Coordinator(Application, pane_ingest_runtime_port);

        fn paneIngestCoordinator(application: *Application) RuntimePaneIngestCoordinator {
            return RuntimePaneIngestCoordinator.init(application, .{
                .io = application.io,
                .panes = &application.model.panes,
                .metrics = &application.metrics,
            });
        }

        fn scheduleIngestObservation(application: *Application, pane: *Pane) !void {
            return schedulePaneObservation(application, pane);
        }

        fn scheduleIngestMedia(application: *Application, pane: *Pane) !void {
            return schedulePaneMedia(application, pane);
        }

        fn refreshPaneClients(application: *Application, pane: *Pane) void {
            for (&application.clients.items) |*slot| {
                const client = slot.* orelse continue;
                const attachment = client.attachments.find(pane.id) orelse continue;

                _ = attachment.resizeIfNeeded() catch {
                    _ = application.detachSessionPane(client, pane.id);
                };
            }
        }

        fn startNextPaneRead(application: *Application, read: pane_ingest_coordinator.Read) !void {
            try application.select.concurrent(.pane_output, pane_launcher_mod.readPane, .{ read.io, read.pane });
        }

        fn pumpRuntimeClients(application: *Application) void {
            application.pumpAll();
        }

        const pane_exit_runtime_port: pane_exit_coordinator.RuntimePort(Application) = .{
            .revoke_credential = revokeExitedPaneCredential,
            .schedule_observation = schedulePaneObservation,
            .collect = collectPaneLifecycle,
            .pump_clients = pumpRuntimeClients,
        };

        const RuntimePaneExitCoordinator = pane_exit_coordinator.Coordinator(Application, pane_exit_runtime_port);

        fn paneExitCoordinator(application: *Application) RuntimePaneExitCoordinator {
            return RuntimePaneExitCoordinator.init(application, .{
                .panes = &application.model.panes,
                .agents = &application.model.agents,
                .metrics = &application.metrics,
            });
        }

        fn revokeExitedPaneCredential(application: *Application, pane: *Pane) void {
            application.revokePaneCredential(pane);
        }

        const pane_observation_runtime_port: pane_observation_coordinator.RuntimePort(Application) = .{
            .start = startPaneObservation,
            .publish_sound = publishObservedAgentSound,
            .schedule_description = AgentEvents.scheduleDescription,
            .collect = collectPaneLifecycle,
            .pump_clients = pumpRuntimeClients,
        };

        const RuntimePaneObservationCoordinator = pane_observation_coordinator.Coordinator(Application, pane_observation_runtime_port);

        fn paneObservationCoordinator(application: *Application) RuntimePaneObservationCoordinator {
            return RuntimePaneObservationCoordinator.init(application, .{
                .io = application.io,
                .panes = &application.model.panes,
                .agents = &application.model.agents,
                .metrics = &application.metrics,
            });
        }

        fn schedulePaneObservation(application: *Application, pane: *Pane) !void {
            var coordinator = paneObservationCoordinator(application);
            return coordinator.schedule(pane);
        }

        fn startPaneObservation(application: *Application, work: pane_observation_coordinator.Work) !void {
            try application.select.concurrent(.pane_observed, observePane, .{work});
        }

        fn observePane(work: pane_observation_coordinator.Work) PaneObservationEvent {
            const path = diagnostics.enter(.observation);
            defer path.restore();

            var stats: history.observer.Stats = .{};
            const process_probe = agent_process.probe(
                work.pane.session.foregroundProcessGroup(),
                work.pane.session.pid,
                work.process_cache,
            );
            work.pane.processHistoryObservation(work.current_size, &stats);
            return .{ .pane = work.pane.key(), .stats = stats, .process_probe = process_probe };
        }

        fn publishObservedAgentSound(application: *Application, notification: schema.AgentSoundNotification) void {
            application.publishAgentSound(notification);
        }

        const pane_media_runtime_port: pane_media_coordinator.RuntimePort(Application) = .{
            .start = startPaneMedia,
            .enforce_quotas = enforcePaneGraphicsQuotas,
            .synchronize_clients = synchronizeMediaClients,
            .schedule_response = PaneIoEvents.scheduleResponse,
            .pump_clients = pumpRuntimeClients,
            .collect = collectPaneLifecycle,
        };

        const RuntimePaneMediaCoordinator = pane_media_coordinator.Coordinator(Application, pane_media_runtime_port);

        fn paneMediaCoordinator(application: *Application) RuntimePaneMediaCoordinator {
            return RuntimePaneMediaCoordinator.init(application, .{
                .panes = &application.model.panes,
                .metrics = &application.metrics,
            });
        }

        fn schedulePaneMedia(application: *Application, pane: *Pane) !void {
            var coordinator = paneMediaCoordinator(application);
            return coordinator.schedule(pane);
        }

        fn startPaneMedia(application: *Application, work: pane_media_coordinator.Work) !void {
            try application.select.concurrent(.pane_media, processPaneMedia, .{work});
        }

        fn processPaneMedia(work: pane_media_coordinator.Work) PaneMediaEvent {
            const path = diagnostics.enter(.media);
            defer path.restore();

            var stats: media_mod.Stats = .{};
            work.pane.processMedia(work.current_size, &stats);
            return .{ .pane = work.pane.key(), .stats = stats };
        }

        fn enforcePaneGraphicsQuotas(application: *Application, pane: *Pane) void {
            enforceGraphicsQuotas(application.io, pane);
        }

        fn synchronizeMediaClients(application: *Application, pane: *Pane, reset: bool) media_projection.Stats {
            var stores: [max_clients]*AttachmentStore = undefined;
            var count: usize = 0;

            for (&application.clients.items) |*slot| {
                const client = slot.* orelse continue;
                stores[count] = &client.attachments;
                count += 1;
            }

            return media_projection.synchronize(pane, stores[0..count], reset);
        }

        pub const request_runtime_port: request_dispatch.RuntimePort(Application) = .{
            .schedule_observation = schedulePaneObservation,
            .schedule_media = schedulePaneMedia,
            .schedule_response = PaneIoEvents.scheduleResponse,
            .schedule_input = PaneIoEvents.scheduleInput,
        };
    };
}

test {
    std.testing.refAllDecls(@This());
}
