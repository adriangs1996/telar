//! Coordinates runtime I/O completions with client input, graphics and message delivery.

const std = @import("std");
const core = @import("telar-core");
const transport = @import("../connection/root.zig").runtime_transport;
const Client = @import("../client.zig");
const host_inputs = @import("../controllers/input/host_inputs.zig");
const server_messages = @import("runtime_messages.zig");
const Io = std.Io;
const schema = core.schema;
const diagnostics = core.diagnostics;
const State = transport.State;
pub const Message = transport.Message;
pub const Snapshot = transport.Snapshot;
pub const capacity = transport.capacity;
pub const max_input_bytes = transport.max_input_bytes;

/// Reports remaining bounded outbound message slots without exposing the
/// queue representation.
///
/// ```zig
/// const available = runtime_transport.availableCapacity(client);
/// ```
pub fn availableCapacity(client: *const Client) usize {
    return client.runtime_transport.outbox.availableCapacity();
}

/// Copies the outbound counters consumed by client telemetry.
///
/// ```zig
/// const snapshot = runtime_transport.snapshot(client);
/// ```
pub fn snapshot(client: *const Client) Snapshot {
    return client.runtime_transport.outbox.snapshot();
}

/// Starts one runtime read while preserving a single outstanding token.
///
/// ```zig
/// try runtime_transport.scheduleRead(client);
/// ```
pub fn scheduleRead(client: *Client) !void {
    const state = &client.runtime_transport;
    if (!state.beginRead()) {
        return;
    }

    client.select.concurrent(.server, receive, .{ client.io, state }) catch |err| {
        state.cancelRead();

        return err;
    };
}

/// Releases one runtime read, dispatches its bounded message and rearms only
/// while the client remains alive.
///
/// ```zig
/// if (try runtime_transport.handleRead(client, result)) |status| return status;
/// ```
pub fn handleRead(client: *Client, result: anyerror![]u8) !?u8 {
    const payload = try client.runtime_transport.completeRead(result);
    const decode_started = diagnostics.now(client.io);
    const message = try schema.decodeServer(payload);
    recordMessage(client, .{
        .payload_len = payload.len,
        .message = message,
        .decode_started_ns = decode_started,
    });
    const status = try server_messages.handleServerMessage(client, message);
    if (status) |exit_status| {
        return exit_status;
    }

    try flushGraphicsCredits(client);
    try scheduleRead(client);

    return null;
}

/// Releases one runtime write, pumps its successor and resumes host input when
/// one queue slot becomes available.
///
/// ```zig
/// try runtime_transport.handleSent(client, result);
/// ```
pub fn handleSent(client: *Client, result: anyerror!void) !void {
    try client.runtime_transport.outbox.finishSend(result);
    try flushGraphicsCredits(client);
    try host_inputs.scheduleRead(client);
}

/// Copies one fixed-size outbound message and starts its write when idle.
///
/// ```zig
/// try runtime_transport.enqueue(client, .{ .detach_pane = detach });
/// ```
pub fn enqueue(client: *Client, message: Message) !void {
    try client.runtime_transport.outbox.push(message);
    try pump(client);
}

/// Copies bounded pane input and starts its write when idle.
///
/// ```zig
/// try runtime_transport.enqueueInput(client, pane_id, bytes);
/// ```
pub fn enqueueInput(client: *Client, pane_id: schema.PaneId, bytes: []const u8) !void {
    if (bytes.len > max_input_bytes) {
        try client.runtime_transport.outbox.pushInputBatch(pane_id, bytes);
    } else {
        try client.runtime_transport.outbox.pushInput(pane_id, bytes);
    }

    try pump(client);
}

/// Copies one tab rename and starts its write when idle.
///
/// ```zig
/// try runtime_transport.enqueueRename(client, rename);
/// ```
pub fn enqueueRename(client: *Client, rename: schema.RenameTab) !void {
    try client.runtime_transport.outbox.pushRename(rename);
    try pump(client);
}

/// Copies one workspace rename and starts its write when idle.
///
/// ```zig
/// try runtime_transport.enqueueWorkspaceRename(client, rename);
/// ```
pub fn enqueueWorkspaceRename(client: *Client, rename: schema.RenameWorkspace) !void {
    try client.runtime_transport.outbox.pushWorkspaceRename(rename);
    try pump(client);
}

/// Copies one workspace creation and starts its write when idle.
///
/// ```zig
/// try runtime_transport.enqueueCreateWorkspace(client, request);
/// ```
pub fn enqueueCreateWorkspace(client: *Client, request: schema.CreateWorkspace) !void {
    try client.runtime_transport.outbox.pushCreateWorkspace(request);
    try pump(client);
}

/// Copies one tab creation and starts its write when idle.
///
/// ```zig
/// try runtime_transport.enqueueCreateTab(client, request);
/// ```
pub fn enqueueCreateTab(client: *Client, request: schema.CreateTab) !void {
    try client.runtime_transport.outbox.pushCreateTab(request);
    try pump(client);
}

/// Copies one notification request and starts its write when idle.
///
/// ```zig
/// try runtime_transport.enqueueNotification(client, request);
/// ```
pub fn enqueueNotification(client: *Client, request: schema.ShowNotification) !void {
    try client.runtime_transport.outbox.pushNotification(request);
    try pump(client);
}

/// Copies and coalesces one complete reconnectable client layout.
///
/// ```zig
/// try runtime_transport.enqueueClientLayout(client, update);
/// ```
pub fn enqueueClientLayout(client: *Client, update: schema.ClientLayoutUpdate) !void {
    try client.runtime_transport.outbox.pushClientLayout(update);
    try pump(client);
}

/// Transfers every graphics credit that fits into the bounded outbox and
/// leaves the rest owned by the graphics store.
///
/// ```zig
/// try runtime_transport.flushGraphicsCredits(client);
/// ```
pub fn flushGraphicsCredits(client: *Client) !void {
    while (client.graphics_store.peekCredit()) |credit| {
        client.runtime_transport.outbox.push(.{ .graphics_credit = .{
            .pane_id = credit.pane_id,
            .bytes = @intCast(credit.bytes),
        } }) catch break;
        client.graphics_store.consumeCredit(credit);
    }

    try pump(client);
}

fn pump(client: *Client) !void {
    const state = &client.runtime_transport;
    const payload = try state.prepareSend() orelse return;
    client.select.concurrent(.sent, send, .{
        client.io,
        state,
        payload,
    }) catch |err| {
        state.cancelSend();

        return err;
    };
}

fn receive(io: Io, state: *State) anyerror![]u8 {
    return state.read(io);
}

fn send(io: Io, state: *State, payload: []const u8) anyerror!void {
    return state.send(io, payload);
}

const DecodedObservation = struct {
    payload_len: usize,
    message: schema.ServerMessage,
    decode_started_ns: u64,
};

fn recordMessage(client: *Client, observation: DecodedObservation) void {
    if (comptime !diagnostics.enabled) {
        return;
    }

    client.telemetry.metrics.server_messages += 1;
    client.telemetry.metrics.server_bytes += observation.payload_len;
    switch (observation.message) {
        .graphics_snapshot,
        .graphics_image,
        .graphics_shared_image,
        .graphics_image_chunk,
        .graphics_placement,
        .graphics_delete_image,
        .graphics_delete_placement,
        => {
            client.telemetry.metrics.graphics_messages += 1;
            client.telemetry.metrics.graphics_bytes += observation.payload_len;
        },
        else => {},
    }
    client.telemetry.metrics.decode.observe(
        diagnostics.elapsed(observation.decode_started_ns, diagnostics.now(client.io)),
    );
}
