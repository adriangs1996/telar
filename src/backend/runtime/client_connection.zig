//! A client connection is admitted, negotiated, read one frame at a time,
//! written one delivery at a time, and dropped. Each connection keeps at
//! most one read and one write actor.

const core = @import("telar-core");
const std = @import("std");
const RuntimeModel = @import("RuntimeModel.zig");
const Session = @import("client/Session.zig");
const ClientKey = @import("../history/ClientKey.zig");
const ClientMessage = @import("events/ClientMessage.zig");
const ClientSent = @import("events/ClientSent.zig");
const LocalListener = @import("../transport/LocalListener.zig");
const Read = @import("client/Read.zig");
const Sources = @import("Sources.zig");
const Write = @import("client/Write.zig");
const client_control = @import("client_control.zig");
const client_request = @import("client_request.zig");
const geometry_lease = @import("geometry_lease.zig");
const handshake = @import("../transport/handshake.zig");
const request_role = @import("client/request_role.zig");

/// Rearms admission and moves an accepted connection into the single
/// handshake slot when capacity and lifecycle allow it.
///
/// ```zig
/// try client_connection.accept(model, result, &resources.listener);
/// ```
pub fn accept(model: *RuntimeModel, result: anyerror!core.SocketChannel, listener: *LocalListener) !void {
    var sources = Sources.init(model.io, model.select);
    var accepted = result catch {
        try sources.acceptClient(listener);
        return;
    };
    var accepted_owned = true;
    defer if (accepted_owned) {
        accepted.deinit(model.io);
    };

    if (model.shutdown.isRequested()) {
        return;
    }

    try sources.acceptClient(listener);

    if (model.client_admission.pendingConnection()) |pending| {
        pending.shutdown(model.io);
        return;
    }

    if (!model.clients.hasCapacity()) {
        return;
    }

    model.client_admission.begin(accepted);
    accepted_owned = false;
    model.select.concurrent(.handshaken, negotiate, .{ model.io, model.client_admission.pendingConnection().? }) catch {
        var unstarted = model.client_admission.takePending();
        unstarted.deinit(model.io);
    };
}

/// Completes the pending handshake and starts the admitted client's first
/// read when negotiation succeeded.
///
/// ```zig
/// client_connection.finishHandshake(model, result);
/// ```
pub fn finishHandshake(model: *RuntimeModel, result: anyerror!void) void {
    var negotiated = model.client_admission.takePending();
    var connection_owned = true;
    defer if (connection_owned) {
        negotiated.deinit(model.io);
    };

    result catch return;

    if (model.shutdown.isRequested()) {
        return;
    }

    const session = model.clients.add(model.gpa, negotiated) catch return;
    connection_owned = false;
    startRead(model, session) catch {
        drop(model, session.key);
    };
}

/// Decodes one client frame, routes it to its flow and rearms the read
/// unless shutdown has started. Delivery happens in the update's flush.
///
/// ```zig
/// client_connection.receive(model, event);
/// ```
pub fn receive(model: *RuntimeModel, event: ClientMessage) void {
    core.mark(model.io, .runtime_dispatch);
    const session = model.clients.resolve(event.client) orelse {
        model.metrics.stale_client_messages += 1;
        return;
    };

    session.read_pending = false;

    if (session.closing) {
        finalize(model, event.client);
        return;
    }

    const payload = event.result catch {
        drop(model, event.client);
        return;
    };
    const decode_started = core.now(model.io);
    const message = core.decodeClient(payload) catch {
        drop(model, event.client);
        return;
    };

    if (comptime core.enabled) {
        model.metrics.client_messages += 1;
        model.metrics.decode.observe(core.elapsed(decode_started, core.now(model.io)));
    }

    if (session.role == .undecided) {
        session.role = switch (request_role.classifyMessage(message)) {
            .ui => .ui,
            .control => .control,
        };
    }

    client_request.receive(model, session, message) catch {
        drop(model, event.client);
        return;
    };

    if (!model.shutdown.isRequested()) {
        startRead(model, session) catch drop(model, event.client);
    }
}

/// Retires one write. The update's flush starts the session's next one.
///
/// ```zig
/// client_connection.finishSend(model, event);
/// ```
pub fn finishSend(model: *RuntimeModel, event: ClientSent) void {
    const session = model.clients.resolve(event.client) orelse {
        model.metrics.stale_client_messages += 1;
        return;
    };

    session.send_pending = false;
    if (session.closing) {
        finalize(model, event.client);
        return;
    }

    const completion = session.delivery.complete(event.result);
    if (completion.close_client) {
        drop(model, event.client);
        return;
    }

    if (completion.detach_pane) |detach| {
        _ = session.attachments.detach(detach);
    }

    if (session.delivery.shouldCloseAfterReply() and !model.shutdown.isRequested()) {
        drop(model, event.client);
    }
}

/// Starts one bounded write and rolls back `send_pending` when the actor
/// cannot be scheduled.
///
/// ```zig
/// try client_connection.startSend(model, session, payload);
/// ```
pub fn startSend(model: *RuntimeModel, session: *Session, payload: []const u8) !void {
    std.debug.assert(!session.send_pending);
    session.send_pending = true;
    model.select.concurrent(.client_sent, send, .{Write{
        .io = model.io,
        .key = session.key,
        .connection = &session.connection,
        .payload = payload,
    }}) catch |err| {
        session.send_pending = false;
        return err;
    };
}

/// Starts idempotent client teardown and removes the session once its read,
/// write and search actors have retired.
///
/// ```zig
/// client_connection.drop(model, session.key);
/// ```
pub fn drop(model: *RuntimeModel, key: ClientKey) void {
    const session = model.clients.resolve(key) orelse return;
    if (!session.closing) {
        client_control.abandon(model, key);
        session.closing = true;
        session.connection.shutdown(model.io);
        session.attachments.deinit();
        session.delivery.close();
        geometry_lease.releaseAll(model, key);
    }

    finalize(model, key);
}

/// Removes a closing client after its read, write and search slots retire.
///
/// ```zig
/// client_connection.finalize(model, key);
/// ```
pub fn finalize(model: *RuntimeModel, key: ClientKey) void {
    const session = model.clients.resolve(key) orelse return;

    if (!session.closing or session.read_pending or session.send_pending or session.search_scheduled) {
        return;
    }

    _ = model.clients.remove(.{ .io = model.io, .gpa = model.gpa }, key);
}

/// Unblocks client actors without releasing the connections they borrow.
/// Example: `client_connection.shutdownAll(model); runtime.loop.cancel();`.
pub fn shutdownAll(model: *RuntimeModel) void {
    for (model.clients.items) |slot| {
        if (slot) |session| {
            session.connection.shutdown(model.io);
        }
    }

    if (model.client_admission.pendingConnection()) |pending| {
        pending.shutdown(model.io);
    }
}

/// Releases connection storage after every client actor has joined.
/// Example: `runtime.loop.cancel(); client_connection.releaseAll(model);`.
pub fn releaseAll(model: *RuntimeModel) void {
    if (model.client_admission.isPending()) {
        var pending = model.client_admission.takePending();
        pending.deinit(model.io);
    }

    for (model.clients.items) |slot| {
        if (slot) |session| {
            session.read_pending = false;
            session.send_pending = false;
            session.search_scheduled = false;
        }
    }

    model.clients.deinit(model.io, model.gpa);
}

fn startRead(model: *RuntimeModel, session: *Session) !void {
    std.debug.assert(!session.read_pending);
    session.read_pending = true;
    model.select.concurrent(.client_message, read, .{Read{
        .io = model.io,
        .key = session.key,
        .connection = &session.connection,
        .buffer = session.receive_buffer,
    }}) catch |err| {
        session.read_pending = false;
        return err;
    };
}

fn negotiate(io: std.Io, connection: *core.SocketChannel) anyerror!void {
    const response = try handshake.perform(io, connection);

    if (response == .rejected) {
        return error.IncompatibleProtocol;
    }
}

fn read(request: Read) ClientMessage {
    const result = request.connection.receive(request.io, request.buffer);
    core.mark(request.io, .runtime_read);
    return .{ .client = request.key, .result = result };
}

fn send(write: Write) ClientSent {
    core.mark(write.io, .runtime_send_start);
    defer core.mark(write.io, .runtime_send_done);
    return .{ .client = write.key, .result = write.connection.send(write.io, write.payload) };
}
