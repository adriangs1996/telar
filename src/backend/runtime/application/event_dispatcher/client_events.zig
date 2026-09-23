const core = @import("telar-core");
const requests = @import("../requests.zig");
const LocalListenerType = @import("../../../transport/LocalListener.zig");
const ClientMessage = @import("../../ClientMessage.zig");
const request_role = @import("../../client/request_role.zig");
const std = @import("std");
const ClientSent = @import("../../ClientSent.zig");
const SessionType = @import("../../client/Session.zig");
const Write = @import("../../client/Write.zig");
const SourcesType = @import("../../Sources.zig");
const handshake_module = @import("../../../transport/handshake.zig");
const Read = @import("../../client/Read.zig");

const Application = @import("../Application.zig");

/// Rearms admission and transfers an accepted connection into the
/// single-flight handshake state when capacity and lifecycle allow it.
///
/// ```zig
/// try ClientEvents.handleAccepted(&application, result, listener);
/// ```
pub fn handleAccepted(application: *Application, result: anyerror!core.SocketChannel, listener: *LocalListenerType) !void {
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
/// unless shutdown has started. Delivery happens in the update's flush.
///
/// ```zig
/// ClientEvents.handleMessage(&application, event);
/// ```
pub fn handleMessage(application: *Application, event: ClientMessage) void {
    core.mark(application.io, .runtime_dispatch);
    const session = application.clients.resolve(event.client) orelse {
        application.metrics.stale_client_messages += 1;
        return;
    };

    session.read_pending = false;

    if (session.closing) {
        application.finalizeClient(event.client);
        return;
    }

    const payload = event.result catch {
        application.dropClient(event.client);
        return;
    };
    const decode_started = core.now(application.io);
    const message = core.decodeClient(payload) catch {
        application.dropClient(event.client);
        return;
    };

    if (comptime core.enabled) {
        application.metrics.client_messages += 1;
        application.metrics.decode.observe(
            core.elapsed(decode_started, core.now(application.io)),
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
        return;
    };

    if (!application.shutdown.isRequested()) {
        startNegotiatedClientRead(application, session) catch application.dropClient(event.client);
    }
}

/// Applies one client-send completion. The update's flush starts the
/// session's next delivery.
///
/// ```zig
/// ClientEvents.handleSent(&application, event);
/// ```
pub fn handleSent(application: *Application, event: ClientSent) void {
    sendCompleted(application, event);
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

fn shutdownAdmissionConnection(runtime: *AdmissionRuntime, connection: *core.SocketChannel) void {
    connection.shutdown(runtime.application.io);
}

fn startClientHandshake(runtime: *AdmissionRuntime, connection: *core.SocketChannel) !void {
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

fn handshakeClient(io: std.Io, connection: *core.SocketChannel) anyerror!void {
    const response = try handshake_module.perform(io, connection);

    if (response == .rejected) {
        return error.IncompatibleProtocol;
    }
}

fn receiveSession(read: Read) ClientMessage {
    const result = read.connection.receive(read.io, read.buffer);
    core.mark(read.io, .runtime_read);
    return .{ .client = read.key, .result = result };
}

fn sendSession(write: Write) ClientSent {
    core.mark(write.io, .runtime_send_start);
    defer core.mark(write.io, .runtime_send_done);
    return .{ .client = write.key, .result = write.connection.send(write.io, write.payload) };
}

fn acceptClient(runtime: *AdmissionRuntime, result: anyerror!core.SocketChannel) !void {
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

fn sendCompleted(application: *Application, event: ClientSent) void {
    const session = application.clients.resolve(event.client) orelse {
        application.metrics.stale_client_messages += 1;
        return;
    };

    session.send_pending = false;
    if (session.closing) {
        application.finalizeClient(event.client);
        return;
    }

    const completion = session.delivery.complete(event.result);
    if (completion.close_client) {
        application.dropClient(event.client);
        return;
    }

    if (completion.detach_pane) |detach| {
        _ = session.attachments.detach(detach);
    }

    if (session.delivery.shouldCloseAfterReply() and !application.shutdown.isRequested()) {
        application.dropClient(event.client);
    }
}
