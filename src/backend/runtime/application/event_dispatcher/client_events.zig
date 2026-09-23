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

const RuntimeModel = @import("../../RuntimeModel.zig");

/// Rearms admission and transfers an accepted connection into the
/// single-flight handshake state when capacity and lifecycle allow it.
///
/// ```zig
/// try ClientEvents.handleAccepted(&model, result, listener);
/// ```
pub fn handleAccepted(model: *RuntimeModel, result: anyerror!core.SocketChannel, listener: *LocalListenerType) !void {
    var runtime: AdmissionRuntime = .{ .model = model, .listener = listener };
    try acceptClient(&runtime, result);
}

/// Completes the pending handshake and starts the admitted client's
/// first read when negotiation succeeded.
///
/// ```zig
/// ClientEvents.handleHandshaken(&model, result);
/// ```
pub fn handleHandshaken(model: *RuntimeModel, result: anyerror!void) void {
    var negotiated = model.client_admission.takePending();
    var connection_owned = true;
    defer if (connection_owned) {
        negotiated.deinit(model.io);
    };

    result catch return;

    if ((model.shutdown.isRequested())) {
        return;
    }

    const session = (model.clients.add(model.gpa, negotiated)) catch return;
    connection_owned = false;
    startNegotiatedClientRead(model, session) catch {
        model.dropClient(session.key);
    };
}

/// Decodes and dispatches one client message, then rearms that session
/// unless shutdown has started. Delivery happens in the update's flush.
///
/// ```zig
/// ClientEvents.handleMessage(&model, event);
/// ```
pub fn handleMessage(model: *RuntimeModel, event: ClientMessage) void {
    core.mark(model.io, .runtime_dispatch);
    const session = model.clients.resolve(event.client) orelse {
        model.metrics.stale_client_messages += 1;
        return;
    };

    session.read_pending = false;

    if (session.closing) {
        model.finalizeClient(event.client);
        return;
    }

    const payload = event.result catch {
        model.dropClient(event.client);
        return;
    };
    const decode_started = core.now(model.io);
    const message = core.decodeClient(payload) catch {
        model.dropClient(event.client);
        return;
    };

    if (comptime core.enabled) {
        model.metrics.client_messages += 1;
        model.metrics.decode.observe(
            core.elapsed(decode_started, core.now(model.io)),
        );
    }

    if (session.role == .undecided) {
        session.role = switch (request_role.classifyMessage(message)) {
            .ui => .ui,
            .control => .control,
        };
    }

    requests.dispatch(model, session, message) catch {
        model.dropClient(event.client);
        return;
    };

    if (!model.shutdown.isRequested()) {
        startNegotiatedClientRead(model, session) catch model.dropClient(event.client);
    }
}

/// Applies one client-send completion. The update's flush starts the
/// session's next delivery.
///
/// ```zig
/// ClientEvents.handleSent(&model, event);
/// ```
pub fn handleSent(model: *RuntimeModel, event: ClientSent) void {
    sendCompleted(model, event);
}

/// Starts one bounded session write and rolls back `send_pending` when
/// the async operation cannot be scheduled.
///
/// ```zig
/// try ClientEvents.startSend(&model, session, payload);
/// ```
pub fn startSend(model: *RuntimeModel, session: *SessionType, payload: []const u8) !void {
    std.debug.assert(!session.send_pending);
    session.send_pending = true;
    model.select.concurrent(.client_sent, sendSession, .{Write{
        .io = model.io,
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
    var sources = SourcesType.init(runtime.model.io, runtime.model.select);
    try sources.acceptClient(runtime.listener);
}

fn shutdownAdmissionConnection(runtime: *AdmissionRuntime, connection: *core.SocketChannel) void {
    connection.shutdown(runtime.model.io);
}

fn startClientHandshake(runtime: *AdmissionRuntime, connection: *core.SocketChannel) !void {
    try runtime.model.select.concurrent(.handshaken, handshakeClient, .{ runtime.model.io, connection });
}

fn startNegotiatedClientRead(model: *RuntimeModel, session: *SessionType) !void {
    std.debug.assert(!session.read_pending);
    session.read_pending = true;
    model.select.concurrent(.client_message, receiveSession, .{Read{
        .io = model.io,
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
        accepted.deinit(runtime.model.io);
    };

    if ((runtime.model.shutdown.isRequested())) {
        return;
    }

    try rearmClientAccept(runtime);

    if (runtime.model.client_admission.isPending()) {
        shutdownAdmissionConnection(runtime, runtime.model.client_admission.pendingConnection().?);
        return;
    }

    if (!(runtime.model.clients.hasCapacity())) {
        return;
    }

    runtime.model.client_admission.begin(accepted);
    accepted_owned = false;
    startClientHandshake(runtime, runtime.model.client_admission.pendingConnection().?) catch {
        var unstarted = runtime.model.client_admission.takePending();
        unstarted.deinit(runtime.model.io);
    };
}

fn sendCompleted(model: *RuntimeModel, event: ClientSent) void {
    const session = model.clients.resolve(event.client) orelse {
        model.metrics.stale_client_messages += 1;
        return;
    };

    session.send_pending = false;
    if (session.closing) {
        model.finalizeClient(event.client);
        return;
    }

    const completion = session.delivery.complete(event.result);
    if (completion.close_client) {
        model.dropClient(event.client);
        return;
    }

    if (completion.detach_pane) |detach| {
        _ = session.attachments.detach(detach);
    }

    if (session.delivery.shouldCloseAfterReply() and !model.shutdown.isRequested()) {
        model.dropClient(event.client);
    }
}
