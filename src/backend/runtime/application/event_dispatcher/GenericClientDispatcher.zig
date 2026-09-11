const SocketChannelType = @import("telar-core").SocketChannel;
const LocalListenerType = @import("../../../transport/LocalListener.zig");
const ClientMessage = @import("../../ClientMessage.zig");
const mark_module = @import("telar-core").mark;
const now_module = @import("telar-core").now;
const decodeClient_module = @import("telar-core").decodeClient;
const enabled_module = @import("telar-core").enabled;
const elapsed_module = @import("telar-core").elapsed;
const request_router = @import("../../client/request_router.zig");
const std = @import("std");
const ClientSent = @import("../../ClientSent.zig");
const SessionType = @import("../../client/Session.zig");
const Write = @import("../../client/Write.zig");
const GenericAcceptPort = @import("../../client/GenericAcceptPort.zig").Type;
const GenericAcceptCoordinator = @import("../../client/GenericAcceptCoordinator.zig").Type;
const SourcesType = @import("../../Sources.zig");
const GenericHandshakePort = @import("../../client/GenericHandshakePort.zig").Type;
const GenericHandshakeCoordinator = @import("../../client/GenericHandshakeCoordinator.zig").Type;
const ClientKeyType = @import("../../../history/ClientKey.zig");
const CompletionType = @import("../../delivery/Completion.zig");
const PaneIdType = @import("telar-core").PaneId;
const GenericRuntimePort = @import("../../client/GenericRuntimePort.zig").Type;
const GenericCoordinator = @import("../../client/GenericCoordinator.zig").Type;
const handshake_module = @import("../../../transport/handshake.zig");
const Read = @import("../../client/Read.zig");

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
        pub fn handleAccepted(application: *Application, result: anyerror!SocketChannelType, listener: *LocalListenerType) !void {
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
        pub fn handleMessage(application: *Application, event: ClientMessage) !bool {
            mark_module(application.io, .runtime_dispatch);
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
            const decode_started = now_module(application.io);
            const message = decodeClient_module(payload) catch {
                application.dropClient(event.client);
                return false;
            };

            if (comptime enabled_module) {
                application.metrics.client_messages += 1;
                application.metrics.decode.observe(
                    elapsed_module(decode_started, now_module(application.io)),
                );
            }

            if (session.role == .undecided) {
                session.role = switch (request_router.classify(std.meta.activeTag(message))) {
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
        pub fn handleSent(application: *Application, event: ClientSent) bool {
            var coordinator = clientSendCoordinator(application);
            return coordinator.handle(.{ .client = event.client, .result = event.result });
        }

        /// Starts one bounded session write and rolls back `send_pending` when
        /// the async operation cannot be scheduled.
        ///
        /// ```zig
        /// try ClientEvents.startSend(&application, session, payload);
        /// ```
        pub fn startSend(application: *Application, session: *SessionType, payload: []const u8) !void {
            std.debug.assert(!session.send_pending);
            session.send_pending = true;
            application.select.concurrent(.client_sent, sendSession, .{Write{
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
            listener: *LocalListenerType,
        };

        const client_accept_runtime_port: GenericAcceptPort(AdmissionRuntime, SocketChannelType) = .{
            .stopping = clientAdmissionStopping,
            .rearm_accept = rearmClientAccept,
            .has_capacity = clientAdmissionHasCapacity,
            .shutdown_connection = shutdownAdmissionConnection,
            .deinit_connection = deinitAdmissionConnection,
            .start_handshake = startClientHandshake,
        };

        const RuntimeAcceptedClientCoordinator = GenericAcceptCoordinator(AdmissionRuntime, SocketChannelType, client_accept_runtime_port);

        fn acceptedClientCoordinator(runtime: *AdmissionRuntime) RuntimeAcceptedClientCoordinator {
            return RuntimeAcceptedClientCoordinator.init(runtime, &runtime.application.client_admission);
        }

        fn clientAdmissionStopping(runtime: *AdmissionRuntime) bool {
            return runtime.application.shutdown.isRequested();
        }

        fn rearmClientAccept(runtime: *AdmissionRuntime) !void {
            var sources = SourcesType.init(runtime.application.io, runtime.application.select);
            try sources.acceptClient(runtime.listener);
        }

        fn clientAdmissionHasCapacity(runtime: *AdmissionRuntime) bool {
            return runtime.application.clients.hasCapacity();
        }

        fn shutdownAdmissionConnection(runtime: *AdmissionRuntime, connection: *SocketChannelType) void {
            connection.shutdown(runtime.application.io);
        }

        fn deinitAdmissionConnection(runtime: *AdmissionRuntime, connection: *SocketChannelType) void {
            connection.deinit(runtime.application.io);
        }

        fn startClientHandshake(runtime: *AdmissionRuntime, connection: *SocketChannelType) !void {
            try runtime.application.select.concurrent(.handshaken, handshakeClient, .{ runtime.application.io, connection });
        }

        const ClientHandshakeTypes = struct {
            pub const Connection = SocketChannelType;
            pub const Session = *SessionType;
        };

        const client_handshake_runtime_port: GenericHandshakePort(Application, ClientHandshakeTypes) = .{
            .stopping = clientHandshakeStopping,
            .deinit_connection = deinitNegotiatedConnection,
            .admit = admitNegotiatedClient,
            .start_receive = startNegotiatedClientRead,
            .drop_session = dropAdmittedClient,
        };

        const RuntimeHandshakenClientCoordinator = GenericHandshakeCoordinator(Application, ClientHandshakeTypes, client_handshake_runtime_port);

        fn handshakenClientCoordinator(application: *Application) RuntimeHandshakenClientCoordinator {
            return RuntimeHandshakenClientCoordinator.init(application, &application.client_admission);
        }

        fn clientHandshakeStopping(application: *Application) bool {
            return application.shutdown.isRequested();
        }

        fn deinitNegotiatedConnection(application: *Application, connection: *SocketChannelType) void {
            connection.deinit(application.io);
        }

        fn admitNegotiatedClient(application: *Application, connection: SocketChannelType) !*SessionType {
            return application.clients.add(application.gpa, connection);
        }

        fn startNegotiatedClientRead(application: *Application, session: *SessionType) !void {
            try startSessionRead(application, session);
        }

        fn dropAdmittedClient(application: *Application, session: *SessionType) void {
            application.dropClient(session.key);
        }

        const ClientSendTypes = struct {
            pub const Client = ClientKeyType;
            pub const Session = *SessionType;
            pub const Completion = CompletionType;
            pub const Detach = PaneIdType;
        };

        const client_send_runtime_port: GenericRuntimePort(Application, ClientSendTypes) = .{
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

        const RuntimeClientSendCoordinator = GenericCoordinator(Application, ClientSendTypes, client_send_runtime_port);

        fn clientSendCoordinator(application: *Application) RuntimeClientSendCoordinator {
            return RuntimeClientSendCoordinator.init(application);
        }

        fn resolveSentClient(application: *Application, client: ClientKeyType) ?*SessionType {
            return application.clients.resolve(client);
        }

        fn recordStaleClientSend(application: *Application) void {
            application.metrics.stale_client_messages += 1;
        }

        fn releaseClientSend(_: *Application, session: *SessionType) void {
            session.send_pending = false;
        }

        fn sentClientIsClosing(_: *Application, session: *SessionType) bool {
            return session.closing;
        }

        fn finalizeSentClient(application: *Application, client: ClientKeyType) void {
            application.finalizeClient(client);
        }

        fn completeClientDelivery(_: *Application, session: *SessionType, result: anyerror!void) CompletionType {
            return session.delivery.complete(result);
        }

        fn dropSentClient(application: *Application, client: ClientKeyType) void {
            application.dropClient(client);
        }

        fn detachAfterClientSend(application: *Application, session: *SessionType, pane: PaneIdType) void {
            _ = session.attachments.detach(pane);
            application.collect();
        }

        fn sentClientShouldCloseAfterReply(_: *Application, session: *SessionType) bool {
            return session.delivery.shouldCloseAfterReply();
        }

        fn clientSendRuntimeStopping(application: *Application) bool {
            return application.shutdown.isRequested();
        }

        fn pumpSentClient(application: *Application, session: *SessionType) !void {
            try application.pump(session);
        }

        fn pumpRuntimeClients(application: *Application) void {
            application.pumpAll();
        }

        fn clientSendShutdownDelivered(application: *Application) bool {
            return application.shutdownDelivered();
        }

        fn handshakeClient(io: std.Io, connection: *SocketChannelType) anyerror!void {
            const response = try handshake_module.perform(io, connection);

            if (response == .rejected) {
                return error.IncompatibleProtocol;
            }
        }

        fn startSessionRead(application: *Application, session: *SessionType) !void {
            std.debug.assert(!session.read_pending);
            session.read_pending = true;
            application.select.concurrent(.client_message, receiveSession, .{Read{
                .io = application.io,
                .key = session.key,
                .connection = &session.connection,
                .buffer = session.receive_buffer,
            }}) catch |err| {
                session.read_pending = false;
                return err;
            };
        }

        fn receiveSession(read: Read) ClientMessage {
            const result = read.connection.receive(read.io, read.buffer);
            mark_module(read.io, .runtime_read);
            return .{ .client = read.key, .result = result };
        }

        fn sendSession(write: Write) ClientSent {
            mark_module(write.io, .runtime_send_start);
            defer mark_module(write.io, .runtime_send_done);
            return .{ .client = write.key, .result = write.connection.send(write.io, write.payload) };
        }
    };
}
