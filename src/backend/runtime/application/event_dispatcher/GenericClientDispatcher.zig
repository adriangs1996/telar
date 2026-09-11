const core = @import("telar-core");
const transport = @import("../../../transport/root.zig");
const source_namespace = @import("client.zig");
const std = @import("std");
const event_sources = @import("../../event_sources.zig");
const delivery_mod = @import("../../delivery/root.zig");
/// Binds client event completions to one concrete Application type.
///
/// ```zig
/// const ClientEvents = Dispatcher(Application);
/// ```
pub fn Type(comptime Application: type) type {
    return struct {
        /// Rearms admission and transfers an accepted connection into the
        /// single-flight handshake state when capacity and lifecycle allow it.
        ///
        /// ```zig
        /// try ClientEvents.handleAccepted(&application, result, listener);
        /// ```
        pub fn handleAccepted(application: *Application, result: anyerror!core.transport.SocketChannel, listener: *transport.local.LocalListener) !void {
            var runtime: AdmissionRuntime = .{ .application = application, .listener = listener };
            var coordinator = acceptedClientCoordinator(&runtime);
            try coordinator.handle(result);
        }

        /// Completes the pending handshake and starts the admitted client's
        /// first read when negotiation succeeded.
        ///
        /// ```zig
        /// ClientEvents.handleHandshaken(&application, result);
        /// ```
        pub fn handleHandshaken(application: *Application, result: anyerror!void) void {
            var coordinator = handshakenClientCoordinator(application);
            coordinator.handle(result);
        }

        /// Decodes and dispatches one client message, then rearms that session
        /// unless shutdown has started. The return value reports whether
        /// shutdown delivery has completed.
        ///
        /// ```zig
        /// const should_stop = try ClientEvents.handleMessage(&application, event);
        /// ```
        pub fn handleMessage(application: *Application, event: source_namespace.ClientMessageEvent) !bool {
            core.echo_trace.mark(application.io, .runtime_dispatch);
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
            const decode_started = source_namespace.diagnostics.now(application.io);
            const message = source_namespace.schema.decodeClient(payload) catch {
                application.dropClient(event.client);
                return false;
            };

            if (comptime source_namespace.diagnostics.enabled) {
                application.metrics.client_messages += 1;
                application.metrics.decode.observe(
                    source_namespace.diagnostics.elapsed(decode_started, source_namespace.diagnostics.now(application.io)),
                );
            }

            if (session.role == .undecided) {
                session.role = switch (source_namespace.client_request_router.classify(std.meta.activeTag(message))) {
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

        /// Applies one client-send completion and reports whether every client
        /// has received the runtime shutdown response.
        ///
        /// ```zig
        /// const should_stop = ClientEvents.handleSent(&application, event);
        /// ```
        pub fn handleSent(application: *Application, event: source_namespace.ClientSentEvent) bool {
            var coordinator = clientSendCoordinator(application);
            return coordinator.handle(.{ .client = event.client, .result = event.result });
        }

        /// Starts one bounded session write and rolls back `send_pending` when
        /// the async operation cannot be scheduled.
        ///
        /// ```zig
        /// try ClientEvents.startSend(&application, session, payload);
        /// ```
        pub fn startSend(application: *Application, session: *source_namespace.ClientSession, payload: []const u8) !void {
            std.debug.assert(!session.send_pending);
            session.send_pending = true;
            application.select.concurrent(.client_sent, sendSession, .{source_namespace.SessionWrite{
                .io = application.io,
                .key = session.key,
                .connection = &session.connection,
                .payload = payload,
            }}) catch |err| {
                session.send_pending = false;
                return err;
            };
        }

        const AdmissionRuntime = struct {
            application: *Application,
            listener: *transport.local.LocalListener,
        };

        const client_accept_runtime_port: source_namespace.client_admission.AcceptPort(AdmissionRuntime, core.transport.SocketChannel) = .{
            .stopping = clientAdmissionStopping,
            .rearm_accept = rearmClientAccept,
            .has_capacity = clientAdmissionHasCapacity,
            .shutdown_connection = shutdownAdmissionConnection,
            .deinit_connection = deinitAdmissionConnection,
            .start_handshake = startClientHandshake,
        };

        const RuntimeAcceptedClientCoordinator = source_namespace.client_admission.AcceptCoordinator(AdmissionRuntime, core.transport.SocketChannel, client_accept_runtime_port);

        fn acceptedClientCoordinator(runtime: *AdmissionRuntime) RuntimeAcceptedClientCoordinator {
            return RuntimeAcceptedClientCoordinator.init(runtime, &runtime.application.client_admission);
        }

        fn clientAdmissionStopping(runtime: *AdmissionRuntime) bool {
            return runtime.application.shutdown.isRequested();
        }

        fn rearmClientAccept(runtime: *AdmissionRuntime) !void {
            var sources = event_sources.Sources.init(runtime.application.io, runtime.application.select);
            try sources.acceptClient(runtime.listener);
        }

        fn clientAdmissionHasCapacity(runtime: *AdmissionRuntime) bool {
            return runtime.application.clients.hasCapacity();
        }

        fn shutdownAdmissionConnection(runtime: *AdmissionRuntime, connection: *core.transport.SocketChannel) void {
            connection.shutdown(runtime.application.io);
        }

        fn deinitAdmissionConnection(runtime: *AdmissionRuntime, connection: *core.transport.SocketChannel) void {
            connection.deinit(runtime.application.io);
        }

        fn startClientHandshake(runtime: *AdmissionRuntime, connection: *core.transport.SocketChannel) !void {
            try runtime.application.select.concurrent(.handshaken, handshakeClient, .{ runtime.application.io, connection });
        }

        const ClientHandshakeTypes = struct {
            pub const Connection = core.transport.SocketChannel;
            pub const Session = *source_namespace.ClientSession;
        };

        const client_handshake_runtime_port: source_namespace.client_admission.HandshakePort(Application, ClientHandshakeTypes) = .{
            .stopping = clientHandshakeStopping,
            .deinit_connection = deinitNegotiatedConnection,
            .admit = admitNegotiatedClient,
            .start_receive = startNegotiatedClientRead,
            .drop_session = dropAdmittedClient,
        };

        const RuntimeHandshakenClientCoordinator = source_namespace.client_admission.HandshakeCoordinator(Application, ClientHandshakeTypes, client_handshake_runtime_port);

        fn handshakenClientCoordinator(application: *Application) RuntimeHandshakenClientCoordinator {
            return RuntimeHandshakenClientCoordinator.init(application, &application.client_admission);
        }

        fn clientHandshakeStopping(application: *Application) bool {
            return application.shutdown.isRequested();
        }

        fn deinitNegotiatedConnection(application: *Application, connection: *core.transport.SocketChannel) void {
            connection.deinit(application.io);
        }

        fn admitNegotiatedClient(application: *Application, connection: core.transport.SocketChannel) !*source_namespace.ClientSession {
            return application.clients.add(application.gpa, connection);
        }

        fn startNegotiatedClientRead(application: *Application, session: *source_namespace.ClientSession) !void {
            try startSessionRead(application, session);
        }

        fn dropAdmittedClient(application: *Application, session: *source_namespace.ClientSession) void {
            application.dropClient(session.key);
        }

        const ClientSendTypes = struct {
            pub const Client = source_namespace.ClientKey;
            pub const Session = *source_namespace.ClientSession;
            pub const Completion = delivery_mod.Completion;
            pub const Detach = source_namespace.schema.PaneId;
        };

        const client_send_runtime_port: source_namespace.client_send_coordinator.RuntimePort(Application, ClientSendTypes) = .{
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

        const RuntimeClientSendCoordinator = source_namespace.client_send_coordinator.Coordinator(Application, ClientSendTypes, client_send_runtime_port);

        fn clientSendCoordinator(application: *Application) RuntimeClientSendCoordinator {
            return RuntimeClientSendCoordinator.init(application);
        }

        fn resolveSentClient(application: *Application, client: source_namespace.ClientKey) ?*source_namespace.ClientSession {
            return application.clients.resolve(client);
        }

        fn recordStaleClientSend(application: *Application) void {
            application.metrics.stale_client_messages += 1;
        }

        fn releaseClientSend(_: *Application, session: *source_namespace.ClientSession) void {
            session.send_pending = false;
        }

        fn sentClientIsClosing(_: *Application, session: *source_namespace.ClientSession) bool {
            return session.closing;
        }

        fn finalizeSentClient(application: *Application, client: source_namespace.ClientKey) void {
            application.finalizeClient(client);
        }

        fn completeClientDelivery(_: *Application, session: *source_namespace.ClientSession, result: anyerror!void) delivery_mod.Completion {
            return session.delivery.complete(result);
        }

        fn dropSentClient(application: *Application, client: source_namespace.ClientKey) void {
            application.dropClient(client);
        }

        fn detachAfterClientSend(application: *Application, session: *source_namespace.ClientSession, pane: source_namespace.schema.PaneId) void {
            _ = session.attachments.detach(pane);
            application.collect();
        }

        fn sentClientShouldCloseAfterReply(_: *Application, session: *source_namespace.ClientSession) bool {
            return session.delivery.shouldCloseAfterReply();
        }

        fn clientSendRuntimeStopping(application: *Application) bool {
            return application.shutdown.isRequested();
        }

        fn pumpSentClient(application: *Application, session: *source_namespace.ClientSession) !void {
            try application.pump(session);
        }

        fn pumpRuntimeClients(application: *Application) void {
            application.pumpAll();
        }

        fn clientSendShutdownDelivered(application: *Application) bool {
            return application.shutdownDelivered();
        }

        fn handshakeClient(io: source_namespace.Io, connection: *core.transport.SocketChannel) anyerror!void {
            const response = try transport.handshake.perform(io, connection);

            if (response == .rejected) {
                return error.IncompatibleProtocol;
            }
        }

        fn startSessionRead(application: *Application, session: *source_namespace.ClientSession) !void {
            std.debug.assert(!session.read_pending);
            session.read_pending = true;
            application.select.concurrent(.client_message, receiveSession, .{source_namespace.SessionRead{
                .io = application.io,
                .key = session.key,
                .connection = &session.connection,
                .buffer = session.receive_buffer,
            }}) catch |err| {
                session.read_pending = false;
                return err;
            };
        }

        fn receiveSession(read: source_namespace.SessionRead) source_namespace.ClientMessageEvent {
            const result = read.connection.receive(read.io, read.buffer);
            core.echo_trace.mark(read.io, .runtime_read);
            return .{ .client = read.key, .result = result };
        }

        fn sendSession(write: source_namespace.SessionWrite) source_namespace.ClientSentEvent {
            core.echo_trace.mark(write.io, .runtime_send_start);
            defer core.echo_trace.mark(write.io, .runtime_send_done);
            return .{ .client = write.key, .result = write.connection.send(write.io, write.payload) };
        }
    };
}
