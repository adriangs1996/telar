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
const localsocket = @import("localsocket");
const LocalListener = localsocket.LocalListener;
const Sources = @import("Sources.zig");
const client_control = @import("client_control.zig");
const path_picker = @import("path_picker.zig");
const client_request = @import("client_request.zig");
const limit_reached = @import("limit_reached.zig");
const geometry_lease = @import("geometry_lease.zig");
const pane_attachment = @import("pane_attachment.zig");
const handshake = @import("../transport/handshake.zig");
const request_role = @import("client/request_role.zig");
const HandshakeCompletion = @import("events/HandshakeCompletion.zig");
const store_support = @import("client/store_support.zig");

/// Rearms admission and moves an accepted connection into a free handshake
/// slot when capacity and lifecycle allow it, so clients that connect
/// together negotiate independently. Handshakes in flight count against
/// client capacity, so every one that finishes has a place; a connection
/// that finds no slot or no capacity is closed. `expireHandshakes`
/// interrupts one that never finishes.
///
/// ```zig
/// try client_connection.accept(model, result, &resources.listener);
/// ```
pub fn accept(model: *RuntimeModel, result: anyerror!localsocket.SocketChannel, listener: *LocalListener) !void {
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

    if (!model.clients.hasCapacityAfter(model.client_admission.count())) {
        return;
    }

    const now_ms = std.Io.Timestamp.now(model.io, .awake).toMilliseconds();
    const slot = model.client_admission.begin(accepted, now_ms) orelse return;
    accepted_owned = false;
    const negotiation: Negotiation = .{
        .io = model.io,
        .slot = slot,
        .connection = model.client_admission.pendingConnection(slot).?,
    };

    model.select.concurrent(.handshaken, negotiate, .{negotiation}) catch {
        var unstarted = model.client_admission.take(slot);
        unstarted.deinit(model.io);
    };
}

/// Completes the pending handshake and starts the admitted client's first
/// read when negotiation succeeded.
///
/// ```zig
/// client_connection.finishHandshake(model, result);
/// ```
pub fn finishHandshake(model: *RuntimeModel, completion: HandshakeCompletion) void {
    var negotiated = model.client_admission.take(completion.slot);
    var connection_owned = true;
    defer if (connection_owned) {
        negotiated.deinit(model.io);
    };

    completion.result catch return;

    if (model.shutdown.isRequested()) {
        return;
    }

    const session = model.clients.add(model.gpa, negotiated) catch return;
    std.debug.assert(model.attachments.len(session.slot) == 0);
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

    client_request.receive(model, session, message) catch |err| {
        // A request that reached a limit is refused; its connection stays.
        limit_reached.refuse(model, session, message, err) catch {
            drop(model, event.client);
            return;
        };
    };

    // A parked report borrows the receive buffer; reading resumes once it
    // is answered.
    if (session.parked != null) {
        return;
    }

    resumeRead(model, session);
}

/// Starts the connection's next read unless one is running or shutdown
/// has begun.
///
/// ```zig
/// client_connection.resumeRead(model, session);
/// ```
pub fn resumeRead(model: *RuntimeModel, session: *Session) void {
    if (model.shutdown.isRequested() or session.read_pending) {
        return;
    }

    startRead(model, session) catch drop(model, session.key);
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
        _ = pane_attachment.release(model, session, detach);
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
        path_picker.release(model, key);
        session.closing = true;
        session.connection.shutdown(model.io);
        pane_attachment.clear(model, session);
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

    if (!session.closing or session.read_pending or session.send_pending or session.search_scheduled or session.descent_pending) {
        return;
    }

    _ = model.clients.remove(.{ .io = model.io, .gpa = model.gpa }, key);
}

/// Interrupts every handshake unfinished after `handshake_deadline_ms`; its
/// actor then fails and its completion frees the slot. Runs on the
/// maintenance tick.
///
/// ```zig
/// client_connection.expireHandshakes(model);
/// ```
pub fn expireHandshakes(model: *RuntimeModel) void {
    const now_ms = std.Io.Timestamp.now(model.io, .awake).toMilliseconds();
    var from: usize = 0;
    while (model.client_admission.expired(now_ms, store_support.handshake_deadline_ms, from)) |slot| : (from = slot + 1) {
        model.client_admission.pendingConnection(slot).?.shutdown(model.io);
    }
}

/// Unblocks client actors without releasing the connections they borrow.
/// Example: `client_connection.shutdownAll(model); runtime.loop.cancel();`.
pub fn shutdownAll(model: *RuntimeModel) void {
    for (model.clients.items) |slot| {
        if (slot) |session| {
            session.connection.shutdown(model.io);
        }
    }

    for (0..store_support.max_pending_handshakes) |slot| {
        if (model.client_admission.pendingConnection(slot)) |pending| {
            pending.shutdown(model.io);
        }
    }
}

/// Releases connection storage after every client actor has joined.
/// Example: `runtime.loop.cancel(); client_connection.releaseAll(model);`.
pub fn releaseAll(model: *RuntimeModel) void {
    for (0..store_support.max_pending_handshakes) |slot| {
        if (model.client_admission.pendingConnection(slot) != null) {
            var pending = model.client_admission.take(slot);
            pending.deinit(model.io);
        }
    }

    for (model.clients.items) |slot| {
        if (slot) |session| {
            session.read_pending = false;
            session.send_pending = false;
            session.search_scheduled = false;
            session.descent_pending = false;
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

const Negotiation = struct {
    io: std.Io,
    slot: usize,
    connection: *localsocket.SocketChannel,
};

fn negotiate(negotiation: Negotiation) HandshakeCompletion {
    return .{
        .slot = negotiation.slot,
        .result = negotiateSchema(negotiation.io, negotiation.connection),
    };
}

fn negotiateSchema(io: std.Io, connection: *localsocket.SocketChannel) anyerror!void {
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

const Write = struct {
    io: std.Io,
    key: ClientKey,
    connection: *localsocket.SocketChannel,
    payload: []const u8,
};

const Read = struct {
    io: std.Io,
    key: ClientKey,
    connection: *localsocket.SocketChannel,
    buffer: []u8,
};
