const requests = @import("../requests.zig");
const SocketChannelType = @import("telar-core").SocketChannel;
const LocalListenerType = @import("../../../transport/LocalListener.zig");
const ClientMessage = @import("../../ClientMessage.zig");
const mark_module = @import("telar-core").mark;
const now_module = @import("telar-core").now;
const decodeClient_module = @import("telar-core").decodeClient;
const enabled_module = @import("telar-core").enabled;
const elapsed_module = @import("telar-core").elapsed;
const request_role = @import("../../client/request_role.zig");
const std = @import("std");
const ClientSent = @import("../../ClientSent.zig");
const SessionType = @import("../../client/Session.zig");
const Write = @import("../../client/Write.zig");
const SourcesType = @import("../../Sources.zig");
const PaneIdType = @import("telar-core").PaneId;
const handshake_module = @import("../../../transport/handshake.zig");
const Read = @import("../../client/Read.zig");

const Application = @import("../Application.zig");

/// Rearms admission and transfers an accepted connection into the
/// single-flight handshake state when capacity and lifecycle allow it.
///
/// ```zig
/// try ClientEvents.handleAccepted(&application, result, listener);
/// ```
pub fn handleAccepted(application: *Application, result: anyerror!SocketChannelType, listener: *LocalListenerType) !void {
    var runtime: AdmissionRuntime = .{ .application = application, .listener = listener };
    try acceptClient(&runtime, result);
}

/// Completes the pending handshake and starts the admitted client's
/// first read when negotiation succeeded.
///
/// ```zig
/// ClientEvents.handleHandshaken(&application, result);
/// ```
pub fn handleHandshaken(application: *Application, result: anyerror!void) void {
    var negotiated = application.client_admission.takePending();
    var connection_owned = true;
    defer if (connection_owned) {
        negotiated.deinit(application.io);
    };

    result catch return;

    if ((application.shutdown.isRequested())) {
        return;
    }

    const session = (application.clients.add(application.gpa, negotiated)) catch return;
    connection_owned = false;
    startNegotiatedClientRead(application, session) catch {
        application.dropClient(session.key);
    };
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
        session.role = switch (request_role.classifyMessage(message)) {
            .ui => .ui,
            .control => .control,
        };
    }

    requests.dispatch(application, session, message) catch {
        application.dropClient(event.client);
        return false;
    };
    application.pump(session) catch {
        application.dropClient(event.client);
        return false;
    };

    if (!application.shutdown.isRequested()) {
        startNegotiatedClientRead(application, session) catch application.dropClient(event.client);
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
    return sendCompleted(application, .{ .client = event.client, .result = event.result });
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

const AdmissionRuntime = @import("AdmissionRuntime.zig");

fn rearmClientAccept(runtime: *AdmissionRuntime) !void {
    var sources = SourcesType.init(runtime.application.io, runtime.application.select);
    try sources.acceptClient(runtime.listener);
}

fn shutdownAdmissionConnection(runtime: *AdmissionRuntime, connection: *SocketChannelType) void {
    connection.shutdown(runtime.application.io);
}

fn startClientHandshake(runtime: *AdmissionRuntime, connection: *SocketChannelType) !void {
    try runtime.application.select.concurrent(.handshaken, handshakeClient, .{ runtime.application.io, connection });
}

fn startNegotiatedClientRead(application: *Application, session: *SessionType) !void {
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

fn detachAfterClientSend(application: *Application, session: *SessionType, pane: PaneIdType) void {
    _ = session.attachments.detach(pane);
    application.collect();
}

fn handshakeClient(io: std.Io, connection: *SocketChannelType) anyerror!void {
    const response = try handshake_module.perform(io, connection);

    if (response == .rejected) {
        return error.IncompatibleProtocol;
    }
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

fn acceptClient(runtime: *AdmissionRuntime, result: anyerror!SocketChannelType) !void {
    var accepted = result catch {
        try rearmClientAccept(runtime);
        return;
    };
    var accepted_owned = true;
    defer if (accepted_owned) {
        accepted.deinit(runtime.application.io);
    };

    if ((runtime.application.shutdown.isRequested())) {
        return;
    }

    try rearmClientAccept(runtime);

    if (runtime.application.client_admission.isPending()) {
        shutdownAdmissionConnection(runtime, runtime.application.client_admission.pendingConnection().?);
        return;
    }

    if (!(runtime.application.clients.hasCapacity())) {
        return;
    }

    runtime.application.client_admission.begin(accepted);
    accepted_owned = false;
    startClientHandshake(runtime, runtime.application.client_admission.pendingConnection().?) catch {
        var unstarted = runtime.application.client_admission.takePending();
        unstarted.deinit(runtime.application.io);
    };
}

fn sendCompleted(application: *Application, event: ClientSent) bool {
    const session = (application.clients.resolve(event.client)) orelse {
        application.metrics.stale_client_messages += 1;
        return false;
    };

    session.send_pending = false;
    if ((session.closing)) {
        application.finalizeClient(event.client);
        return (application.shutdownDelivered());
    }

    const completion = (session.delivery.complete(event.result));
    if (completion.close_client) {
        application.dropClient(event.client);
        return (application.shutdownDelivered());
    }

    if (completion.detach_pane) |detach| {
        detachAfterClientSend(application, session, detach);
    }

    if ((session.delivery.shouldCloseAfterReply()) and
        !(application.shutdown.isRequested()))
    {
        application.dropClient(event.client);
        return false;
    }

    application.pump(session) catch {
        application.dropClient(event.client);
    };

    if (!(application.shutdown.isRequested())) {
        return false;
    }

    application.pumpAll();
    return (application.shutdownDelivered());
}
