//! Adapters between application state and asynchronous runtime actors.

const std = @import("std");
const core = @import("telar-core");
const agent_mod = @import("../../agent/root.zig");
const coordinators = @import("coordinators/root.zig");
const agent_description_coordinator = coordinators.agent_description;
const agent_maintenance_coordinator = coordinators.agent_maintenance;
const agent_process = @import("../../process/root.zig");
const history = @import("../../history/root.zig");
const event_entrypoints = @import("../entrypoints/events/root.zig");
const history_response_controller = event_entrypoints.history_response;
const attachment_mod = @import("../attachment/root.zig");
const client_runtime = @import("../client/root.zig");
const client_admission = client_runtime.admission;
const client_request_router = client_runtime.request_router;
const client_session = client_runtime.session;
const client_send_coordinator = client_runtime.send_coordinator;
const client_store = client_runtime.store;
const runtime_config = @import("../config.zig");
const delivery_mod = @import("../delivery/root.zig");
const runtime_event = @import("../event.zig");
const event_sources = @import("../event_sources.zig");
const request_dispatch = @import("request_dispatch.zig");
const pane_events = event_entrypoints.pane;
const media_projection = pane_events.media_projection;
const pane_launcher_mod = @import("pane_launcher.zig");
const pane_exit_coordinator = pane_events.exit;
const pane_ingest_coordinator = pane_events.ingest;
const pane_input_pump = pane_events.input;
const pane_media_coordinator = pane_events.media;
const pane_observation_coordinator = pane_events.observation;
const pane_output_pipeline = pane_events.output;
const pane_response_pump = pane_events.response;
const pane_mod = @import("../../pane/root.zig");
const media_mod = @import("../../media/root.zig");
const proxy_observation_adapter = event_entrypoints.proxy_observation;
const observability = @import("../observability/root.zig");
const system_metrics_mod = observability.system_metrics;
const system_metrics_coordinator = observability.system_metrics_coordinator;
const telemetry_mod = observability.telemetry;
const telemetry_tick_coordinator = observability.telemetry_tick_coordinator;
const transport = @import("../../transport/root.zig");

const Io = std.Io;
const schema = core.schema;
const diagnostics = core.diagnostics;

const Pane = pane_mod.Pane;
const AttachmentStore = attachment_mod.AttachmentStore;
const enforceGraphicsQuotas = attachment_mod.enforceGraphicsQuotas;
const TelemetryState = telemetry_mod.State;
const formatRuntimeTelemetry = telemetry_mod.formatRuntimeTelemetry;
const max_clients = client_store.max_clients;
const ResponseQueue = delivery_mod.ResponseQueue;

const IngestTestGate = runtime_config.IngestTestGate;
const ClientKey = client_session.Key;
const RuntimeEvent = runtime_event.Event;
const ClientMessageEvent = runtime_event.ClientMessage;
const ClientSentEvent = runtime_event.ClientSent;
const PaneIngestEvent = pane_ingest_coordinator.Completion;
const PaneObservationEvent = pane_observation_coordinator.Completion;
const PaneMediaEvent = pane_media_coordinator.Completion;
const PaneInputEvent = pane_input_pump.Completion;
const PaneResponseEvent = pane_response_pump.Completion;
const ClientSession = client_session.Session;
const SessionWrite = client_session.Write;
const SessionRead = client_session.Read;

/// Builds the zero-allocation actor bindings for one application type.
///
/// ```zig
/// const Actors = Bindings(Application);
/// ```
pub fn Bindings(comptime Application: type) type {
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
                    var runtime: ClientAdmissionRuntime = .{ .application = application, .listener = resources.listener };
                    var coordinator = acceptedClientCoordinator(&runtime);
                    try coordinator.handle(result);
                },
                .handshaken => |result| {
                    var coordinator = handshakenClientCoordinator(application);
                    coordinator.handle(result);
                },
                .client_message => |value| return handleClientMessageEvent(application, value),
                .client_sent => |value| {
                    var coordinator = clientSendCoordinator(application);
                    return coordinator.handle(.{ .client = value.client, .result = value.result });
                },
                .history_response => |result| {
                    var controller = historyResponseController(application);
                    try controller.handle(result);
                },
                .proxy_event => |result| {
                    var adapter = proxyObservationAdapter(application);
                    try adapter.handle(result);
                },
                .agent_tick => |result| {
                    var coordinator = agentMaintenanceCoordinator(application);
                    try coordinator.handle(result);
                },
                .agent_description => |result| {
                    var coordinator = agentDescriptionCoordinator(application);
                    coordinator.handle(result);
                },
                .metrics_tick => |result| {
                    var coordinator = systemMetricsCoordinator(application);
                    try coordinator.handle(result);
                },
                .pane_input_written => |value| {
                    var input_pump = paneInputPump(application);
                    try input_pump.complete(value);
                },
                .pane_response_written => |value| {
                    var response_pump = paneResponsePump(application);
                    try response_pump.complete(value);
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
                    var coordinator = telemetryTickCoordinator(application, resources.telemetry);
                    coordinator.handle(result);
                },
                .telemetry_written => |result| switch (resources.telemetry.finishWrite(result)) {
                    .ready => {},
                    .disable_sink => resources.telemetry.deinit(application.io),
                },
            }

            return false;
        }

        fn handleClientMessageEvent(application: *Application, event: ClientMessageEvent) !bool {
            const session = application.clients.resolve(event.client) orelse {
                application.metrics.stale_client_messages += 1;
                return false;
            };

            session.read_pending = false;

            if (session.closing) {
                application.finalizeClient(event.client);
                return false;
            }

            const payload = event.result catch {
                application.dropClient(event.client);
                return false;
            };
            const decode_started = diagnostics.now(application.io);
            const message = schema.decodeClient(payload) catch {
                application.dropClient(event.client);
                return false;
            };

            if (comptime diagnostics.enabled) {
                application.metrics.client_messages += 1;
                application.metrics.decode.observe(
                    diagnostics.elapsed(decode_started, diagnostics.now(application.io)),
                );
            }

            if (session.role == .undecided) {
                session.role = switch (client_request_router.classify(std.meta.activeTag(message))) {
                    .ui => .ui,
                    .control => .control,
                };
            }

            application.dispatchClientMessage(session, message) catch {
                application.dropClient(event.client);
                return false;
            };
            application.pump(session) catch {
                application.dropClient(event.client);
                return false;
            };

            if (!application.shutdown.isRequested()) {
                startSessionRead(application, session) catch application.dropClient(event.client);
                return false;
            }

            application.pumpAll();
            return application.shutdownDelivered();
        }

        fn queueFailure(responses: *ResponseQueue, failure: delivery_mod.PendingFailure) !void {
            try responses.push(.{ .request_failed = .{
                .request_id = failure.request_id,
                .code = failure.code,
                .message = failure.message,
            } });
        }

        /// Schedules a bounded client write after delivery prepared its payload.
        ///
        /// ```zig
        /// try Actors.startSessionSend(&application, session, payload);
        /// ```
        pub fn startSessionSend(application: *Application, session: *ClientSession, payload: []const u8) !void {
            std.debug.assert(!session.send_pending);
            session.send_pending = true;
            application.select.concurrent(.client_sent, sendSession, .{SessionWrite{
                .io = application.io,
                .key = session.key,
                .connection = &session.connection,
                .payload = payload,
            }}) catch |err| {
                session.send_pending = false;
                return err;
            };
        }

        fn sendSession(write: SessionWrite) ClientSentEvent {
            return .{ .client = write.key, .result = write.connection.send(write.io, write.payload) };
        }

        fn writeDiagnostics(io: Io, state: *TelemetryState, bytes: []const u8) anyerror!void {
            try state.write(io, bytes);
        }

        const ClientAdmissionRuntime = struct {
            application: *Application,
            listener: *transport.local.LocalListener,
        };

        const client_accept_runtime_port: client_admission.AcceptPort(ClientAdmissionRuntime, core.transport.SocketChannel) = .{
            .stopping = clientAdmissionStopping,
            .rearm_accept = rearmClientAccept,
            .has_capacity = clientAdmissionHasCapacity,
            .shutdown_connection = shutdownAdmissionConnection,
            .deinit_connection = deinitAdmissionConnection,
            .start_handshake = startClientHandshake,
        };

        const RuntimeAcceptedClientCoordinator = client_admission.AcceptCoordinator(ClientAdmissionRuntime, core.transport.SocketChannel, client_accept_runtime_port);

        fn acceptedClientCoordinator(runtime: *ClientAdmissionRuntime) RuntimeAcceptedClientCoordinator {
            return RuntimeAcceptedClientCoordinator.init(runtime, &runtime.application.client_admission);
        }

        fn clientAdmissionStopping(runtime: *ClientAdmissionRuntime) bool {
            return runtime.application.shutdown.isRequested();
        }

        fn rearmClientAccept(runtime: *ClientAdmissionRuntime) !void {
            var sources = eventSources(runtime.application);
            try sources.acceptClient(runtime.listener);
        }

        fn clientAdmissionHasCapacity(runtime: *ClientAdmissionRuntime) bool {
            return runtime.application.clients.hasCapacity();
        }

        fn shutdownAdmissionConnection(runtime: *ClientAdmissionRuntime, connection: *core.transport.SocketChannel) void {
            connection.shutdown(runtime.application.io);
        }

        fn deinitAdmissionConnection(runtime: *ClientAdmissionRuntime, connection: *core.transport.SocketChannel) void {
            connection.deinit(runtime.application.io);
        }

        fn startClientHandshake(runtime: *ClientAdmissionRuntime, connection: *core.transport.SocketChannel) !void {
            try runtime.application.select.concurrent(.handshaken, handshakeClient, .{ runtime.application.io, connection });
        }

        const ClientHandshakeTypes = struct {
            pub const Connection = core.transport.SocketChannel;
            pub const Session = *ClientSession;
        };

        const client_handshake_runtime_port: client_admission.HandshakePort(Application, ClientHandshakeTypes) = .{
            .stopping = clientHandshakeStopping,
            .deinit_connection = deinitNegotiatedConnection,
            .admit = admitNegotiatedClient,
            .start_receive = startNegotiatedClientRead,
            .drop_session = dropAdmittedClient,
        };

        const RuntimeHandshakenClientCoordinator = client_admission.HandshakeCoordinator(Application, ClientHandshakeTypes, client_handshake_runtime_port);

        fn handshakenClientCoordinator(application: *Application) RuntimeHandshakenClientCoordinator {
            return RuntimeHandshakenClientCoordinator.init(application, &application.client_admission);
        }

        fn clientHandshakeStopping(application: *Application) bool {
            return application.shutdown.isRequested();
        }

        fn deinitNegotiatedConnection(application: *Application, connection: *core.transport.SocketChannel) void {
            connection.deinit(application.io);
        }

        fn admitNegotiatedClient(application: *Application, connection: core.transport.SocketChannel) !*ClientSession {
            return application.clients.add(application.gpa, connection);
        }

        fn startNegotiatedClientRead(application: *Application, session: *ClientSession) !void {
            try startSessionRead(application, session);
        }

        fn dropAdmittedClient(application: *Application, session: *ClientSession) void {
            application.dropClient(session.key);
        }

        const ClientSendTypes = struct {
            pub const Client = ClientKey;
            pub const Session = *ClientSession;
            pub const Completion = delivery_mod.Completion;
            pub const Detach = schema.PaneId;
        };

        const client_send_runtime_port: client_send_coordinator.RuntimePort(Application, ClientSendTypes) = .{
            .resolve = resolveSentClient,
            .record_stale = recordStaleClientSend,
            .release_send = releaseClientSend,
            .is_closing = sentClientIsClosing,
            .finalize = finalizeSentClient,
            .complete_delivery = completeClientDelivery,
            .drop_client = dropSentClient,
            .detach_after_send = detachAfterClientSend,
            .should_close_after_reply = sentClientShouldCloseAfterReply,
            .stopping = clientSendRuntimeStopping,
            .pump_client = pumpSentClient,
            .pump_all = pumpRuntimeClients,
            .shutdown_delivered = clientSendShutdownDelivered,
        };

        const RuntimeClientSendCoordinator = client_send_coordinator.Coordinator(Application, ClientSendTypes, client_send_runtime_port);

        fn clientSendCoordinator(application: *Application) RuntimeClientSendCoordinator {
            return RuntimeClientSendCoordinator.init(application);
        }

        fn resolveSentClient(application: *Application, client: ClientKey) ?*ClientSession {
            return application.clients.resolve(client);
        }

        fn recordStaleClientSend(application: *Application) void {
            application.metrics.stale_client_messages += 1;
        }

        fn releaseClientSend(_: *Application, session: *ClientSession) void {
            session.send_pending = false;
        }

        fn sentClientIsClosing(_: *Application, session: *ClientSession) bool {
            return session.closing;
        }

        fn finalizeSentClient(application: *Application, client: ClientKey) void {
            application.finalizeClient(client);
        }

        fn completeClientDelivery(_: *Application, session: *ClientSession, result: anyerror!void) delivery_mod.Completion {
            return session.delivery.complete(result);
        }

        fn dropSentClient(application: *Application, client: ClientKey) void {
            application.dropClient(client);
        }

        fn detachAfterClientSend(application: *Application, session: *ClientSession, pane: schema.PaneId) void {
            _ = session.attachments.detach(pane);
            application.collect();
        }

        fn sentClientShouldCloseAfterReply(_: *Application, session: *ClientSession) bool {
            return session.delivery.shouldCloseAfterReply();
        }

        fn clientSendRuntimeStopping(application: *Application) bool {
            return application.shutdown.isRequested();
        }

        fn pumpSentClient(application: *Application, session: *ClientSession) !void {
            try application.pump(session);
        }

        fn clientSendShutdownDelivered(application: *Application) bool {
            return application.shutdownDelivered();
        }

        const history_response_runtime_port: history_response_controller.RuntimePort(Application, *ClientSession) = .{
            .rearm_receive = rearmHistoryResponse,
            .resolve = resolveHistoryResponseClient,
            .set_close_after_reply = setHistoryCloseAfterReply,
            .enqueue_query_result = enqueueHistoryQueryResult,
            .enqueue_failure = enqueueHistoryFailure,
            .dispose_query_result = disposeHistoryQueryResult,
            .pump_clients = pumpRuntimeClients,
        };

        const RuntimeHistoryResponseController = history_response_controller.Controller(Application, *ClientSession, history_response_runtime_port);

        fn historyResponseController(application: *Application) RuntimeHistoryResponseController {
            return RuntimeHistoryResponseController.init(application);
        }

        fn rearmHistoryResponse(application: *Application) !void {
            try application.select.concurrent(.history_response, history.receiveResponse, .{ application.io, application.history_service });
        }

        fn resolveHistoryResponseClient(application: *Application, client: ClientKey) ?*ClientSession {
            return application.clients.resolve(client);
        }

        fn setHistoryCloseAfterReply(_: *Application, session: *ClientSession, enabled: bool) void {
            session.delivery.setCloseAfterReply(enabled);
        }

        fn enqueueHistoryQueryResult(_: *Application, session: *ClientSession, result: *history.model.QueryResult) bool {
            session.delivery.responses.push(.{ .history_result = result }) catch return false;
            return true;
        }

        fn enqueueHistoryFailure(_: *Application, session: *ClientSession, failure: history.model.Failure) bool {
            queueFailure(&session.delivery.responses, .{
                .request_id = failure.request_id,
                .code = .internal,
                .message = failure.message,
            }) catch return false;
            return true;
        }

        fn disposeHistoryQueryResult(_: *Application, result: *history.model.QueryResult) void {
            result.deinit();
        }

        const pane_input_runtime_port: pane_input_pump.RuntimePort(Application) = .{
            .start = startPaneInputWrite,
            .collect = collectPaneLifecycle,
        };

        const RuntimePaneInputPump = pane_input_pump.Pump(Application, pane_input_runtime_port);

        fn paneInputPump(application: *Application) RuntimePaneInputPump {
            return RuntimePaneInputPump.init(application, .{
                .io = application.io,
                .panes = &application.model.panes,
                .metrics = &application.metrics,
            });
        }

        fn startPaneInputWrite(application: *Application, write: pane_input_pump.Write) !void {
            try application.select.concurrent(.pane_input_written, writePaneInput, .{write});
        }

        fn collectPaneLifecycle(application: *Application) void {
            application.collect();
        }

        fn writePaneInput(write: pane_input_pump.Write) PaneInputEvent {
            const path = diagnostics.enter(.interactive);
            defer path.restore();

            write.pane.pty_write_mutex.lockUncancelable(write.io);
            defer write.pane.pty_write_mutex.unlock(write.io);

            return .{
                .pane = write.pane.key(),
                .started_ns = write.started_ns,
                .result = write.pane.session.file().writeStreamingAll(write.io, write.bytes),
            };
        }

        const pane_response_runtime_port: pane_response_pump.RuntimePort(Application) = .{
            .start = startPaneResponseWrite,
            .collect = collectPaneLifecycle,
        };

        const RuntimePaneResponsePump = pane_response_pump.Pump(Application, pane_response_runtime_port);

        fn paneResponsePump(application: *Application) RuntimePaneResponsePump {
            return RuntimePaneResponsePump.init(application, .{
                .io = application.io,
                .panes = &application.model.panes,
                .metrics = &application.metrics,
            });
        }

        fn schedulePaneResponse(application: *Application, pane: *Pane) !void {
            var response_pump = paneResponsePump(application);
            return response_pump.schedule(pane);
        }

        fn startPaneResponseWrite(application: *Application, write: pane_response_pump.Write) !void {
            try application.select.concurrent(.pane_response_written, writePaneResponse, .{write});
        }

        fn writePaneResponse(write: pane_response_pump.Write) PaneResponseEvent {
            const path = diagnostics.enter(.interactive);
            defer path.restore();

            write.pane.pty_write_mutex.lockUncancelable(write.io);
            defer write.pane.pty_write_mutex.unlock(write.io);

            return .{
                .pane = write.pane.key(),
                .result = write.pane.session.file().writeStreamingAll(write.io, write.bytes),
            };
        }

        fn handshakeClient(io: Io, connection: *core.transport.SocketChannel) anyerror!void {
            const response = try transport.handshake.perform(io, connection);

            if (response == .rejected) {
                return error.IncompatibleProtocol;
            }
        }

        fn startSessionRead(application: *Application, session: *ClientSession) !void {
            std.debug.assert(!session.read_pending);
            session.read_pending = true;
            application.select.concurrent(.client_message, receiveSession, .{SessionRead{
                .io = application.io,
                .key = session.key,
                .connection = &session.connection,
                .buffer = session.receive_buffer,
            }}) catch |err| {
                session.read_pending = false;
                return err;
            };
        }

        fn receiveSession(read: SessionRead) ClientMessageEvent {
            return .{ .client = read.key, .result = read.connection.receive(read.io, read.buffer) };
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
            .schedule_response = schedulePaneResponse,
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

        const agent_description_runtime_port: agent_description_coordinator.RuntimePort(Application) = .{
            .start = startAgentDescription,
            .persist = persistAgentDescription,
            .pump_clients = pumpRuntimeClients,
        };

        const RuntimeAgentDescriptionCoordinator = agent_description_coordinator.Coordinator(Application, agent_description_runtime_port);

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
            var sources = eventSources(application);
            try sources.waitForAgentMaintenance();
        }

        fn runtimeWallClockMs(application: *Application) i64 {
            return Io.Timestamp.now(application.io, .real).toMilliseconds();
        }

        const system_metrics_runtime_port: system_metrics_coordinator.RuntimePort(Application) = .{
            .rearm_tick = rearmSystemMetrics,
            .sample = sampleSystemMetrics,
            .pump_clients = pumpRuntimeClients,
        };

        const RuntimeSystemMetricsCoordinator = system_metrics_coordinator.Coordinator(Application, system_metrics_runtime_port);

        fn systemMetricsCoordinator(application: *Application) RuntimeSystemMetricsCoordinator {
            return RuntimeSystemMetricsCoordinator.init(application, .{ .sampler = &application.system_metrics });
        }

        fn rearmSystemMetrics(application: *Application) !void {
            var sources = eventSources(application);
            try sources.waitForSystemMetrics();
        }

        fn sampleSystemMetrics(_: *Application, sampler: *system_metrics_mod.Sampler) void {
            sampler.sample();
        }

        const proxy_observation_runtime_port: proxy_observation_adapter.RuntimePort(Application) = .{
            .rearm_receive = rearmProxyObservation,
            .schedule_description = scheduleAgentDescriptionWork,
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
            var sources = eventSources(application);
            try sources.receiveProxyObservation(application.proxy_runtime);
        }

        const telemetry_tick_runtime_port: telemetry_tick_coordinator.RuntimePort(Application) = .{
            .available = telemetryAvailable,
            .disable = disableTelemetry,
            .schedule_tick = scheduleTelemetryTick,
            .format_sample = formatTelemetrySample,
            .schedule_write = scheduleTelemetryWrite,
        };

        const RuntimeTelemetryTickCoordinator = telemetry_tick_coordinator.Coordinator(Application, telemetry_tick_runtime_port);

        fn telemetryTickCoordinator(application: *Application, state: *TelemetryState) RuntimeTelemetryTickCoordinator {
            return RuntimeTelemetryTickCoordinator.init(application, state);
        }

        fn telemetryAvailable(_: *Application, state: *const TelemetryState) bool {
            return state.available();
        }

        fn disableTelemetry(application: *Application, state: *TelemetryState) void {
            state.deinit(application.io);
        }

        fn scheduleTelemetryTick(application: *Application) !void {
            var sources = eventSources(application);
            try sources.waitForTelemetry();
        }

        fn eventSources(application: *Application) event_sources.Sources {
            return event_sources.Sources.init(application.io, application.select);
        }

        fn formatTelemetrySample(application: *Application, buffer: []u8) ![]const u8 {
            var attachment_stores: [max_clients]*const AttachmentStore = undefined;
            var attachment_count: usize = 0;
            var clients: telemetry_mod.ClientSample = .{ .count = application.clients.count };

            for (&application.clients.items) |*slot| {
                const session = slot.* orelse continue;
                attachment_stores[attachment_count] = &session.attachments;
                attachment_count += 1;
                clients.response_queue_depth += session.delivery.responses.len;
                clients.response_queue_high_water += session.delivery.responses.high_water;
                clients.response_queue_dropped +|= session.delivery.responses.dropped;
            }

            clients.attachment_stores = attachment_stores[0..attachment_count];

            const proxy_metrics = application.proxy_runtime.metrics();
            const workspaces = application.workspaceReader();

            return formatRuntimeTelemetry(buffer, .{
                .io = application.io,
                .metrics = &application.metrics,
                .clients = clients,
                .workspace_count = workspaces.count(),
                .tab_count = workspaces.totalTabs(),
                .panes = &application.model.panes,
                .history_service = application.history_service,
                .proxy = .{
                    .active = application.proxy_runtime.active(),
                    .active_connections = proxy_metrics.active_connections,
                    .event_queue_depth = proxy_metrics.queued_events,
                    .event_queue_high_water = proxy_metrics.event_queue_high_water,
                    .dropped_events = proxy_metrics.dropped_events,
                    .rejected_connections = proxy_metrics.rejected_connections,
                    .invalid_authorization_rejections = proxy_metrics.invalid_authorization_rejections,
                    .unknown_credential_rejections = proxy_metrics.unknown_credential_rejections,
                    .connection_limit_drops = proxy_metrics.connection_limit_drops,
                    .h2_decode_failures = proxy_metrics.h2_decode_failures,
                    .passthrough_connections = proxy_metrics.passthrough_connections,
                    .upstream_connect_failures = proxy_metrics.upstream_connect_failures,
                    .tls_context_failures = proxy_metrics.tls_context_failures,
                    .tls_upstream_handshake_failures = proxy_metrics.tls_upstream_handshake_failures,
                    .tls_downstream_handshake_failures = proxy_metrics.tls_downstream_handshake_failures,
                    .tls_mint_failures = proxy_metrics.tls_mint_failures,
                    .claude_inference_requests = proxy_metrics.claude_inference_requests,
                    .claude_sse_payload_fragments = proxy_metrics.claude_sse_payload_fragments,
                    .claude_turn_completions = proxy_metrics.claude_turn_completions,
                    .claude_successful_responses = proxy_metrics.claude_successful_responses,
                    .claude_failure_observations = proxy_metrics.claude_failure_observations,
                },
                .heap = application.heap,
            });
        }

        fn scheduleTelemetryWrite(application: *Application, state: *TelemetryState, line: []const u8) !void {
            try application.select.concurrent(.telemetry_written, writeDiagnostics, .{ application.io, state, line });
        }

        const pane_observation_runtime_port: pane_observation_coordinator.RuntimePort(Application) = .{
            .start = startPaneObservation,
            .publish_sound = publishObservedAgentSound,
            .schedule_description = scheduleAgentDescriptionWork,
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

        fn scheduleAgentDescriptionWork(application: *Application) void {
            var coordinator = agentDescriptionCoordinator(application);
            _ = coordinator.schedule();
        }

        const pane_media_runtime_port: pane_media_coordinator.RuntimePort(Application) = .{
            .start = startPaneMedia,
            .enforce_quotas = enforcePaneGraphicsQuotas,
            .synchronize_clients = synchronizeMediaClients,
            .schedule_response = schedulePaneResponse,
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
            .schedule_response = schedulePaneResponse,
            .schedule_input = schedulePaneInput,
        };

        fn schedulePaneInput(application: *Application, pane: *Pane) !void {
            var input_pump = paneInputPump(application);
            return input_pump.schedule(pane);
        }
    };
}

test {
    std.testing.refAllDecls(@This());
}
