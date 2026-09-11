//! Coordinates runtime I/O completions with client input, graphics and message delivery.

const Client = @import("../Client.zig");
const Snapshot = @import("telar-client").OutboxSnapshot;
const mark_module = @import("telar-core").mark;
const now_module = @import("telar-core").now;
const decodeServer_module = @import("telar-core").decodeServer;
const server_messages = @import("runtime_messages.zig");
const host_inputs = @import("../controllers/input/host_inputs.zig");
const Message = @import("telar-client").Message;
const PaneIdType = @import("telar-core").PaneId;
const max_encoded_bytes = @import("telar-client").max_encoded_bytes;
const RenameTabType = @import("telar-core").RenameTab;
const RenameWorkspaceType = @import("telar-core").RenameWorkspace;
const CreateWorkspaceType = @import("telar-core").CreateWorkspace;
const CreateTabType = @import("telar-core").CreateTab;
const ShowNotificationType = @import("telar-core").ShowNotification;
const ClientLayoutUpdateType = @import("telar-core").ClientLayoutUpdate;
const std = @import("std");
const RuntimeTransportState = @import("telar-client").RuntimeTransportState;
const DecodedObservation = @import("DecodedObservation.zig");
const enabled_module = @import("telar-core").enabled;
const elapsed_module = @import("telar-core").elapsed;

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
    mark_module(client.io, .client_frame);
    const payload = try client.runtime_transport.completeRead(result);
    const decode_started = now_module(client.io);
    const message = try decodeServer_module(payload);
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
pub fn enqueueInput(client: *Client, pane_id: PaneIdType, bytes: []const u8) !void {
    if (bytes.len > max_encoded_bytes) {
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
pub fn enqueueRename(client: *Client, rename: RenameTabType) !void {
    try client.runtime_transport.outbox.pushRename(rename);
    try pump(client);
}

/// Copies one workspace rename and starts its write when idle.
///
/// ```zig
/// try runtime_transport.enqueueWorkspaceRename(client, rename);
/// ```
pub fn enqueueWorkspaceRename(client: *Client, rename: RenameWorkspaceType) !void {
    try client.runtime_transport.outbox.pushWorkspaceRename(rename);
    try pump(client);
}

/// Copies one workspace creation and starts its write when idle.
///
/// ```zig
/// try runtime_transport.enqueueCreateWorkspace(client, request);
/// ```
pub fn enqueueCreateWorkspace(client: *Client, request: CreateWorkspaceType) !void {
    try client.runtime_transport.outbox.pushCreateWorkspace(request);
    try pump(client);
}

/// Copies one tab creation and starts its write when idle.
///
/// ```zig
/// try runtime_transport.enqueueCreateTab(client, request);
/// ```
pub fn enqueueCreateTab(client: *Client, request: CreateTabType) !void {
    try client.runtime_transport.outbox.pushCreateTab(request);
    try pump(client);
}

/// Copies one notification request and starts its write when idle.
///
/// ```zig
/// try runtime_transport.enqueueNotification(client, request);
/// ```
pub fn enqueueNotification(client: *Client, request: ShowNotificationType) !void {
    try client.runtime_transport.outbox.pushNotification(request);
    try pump(client);
}

/// Copies and coalesces one complete reconnectable client layout.
///
/// ```zig
/// try runtime_transport.enqueueClientLayout(client, update);
/// ```
pub fn enqueueClientLayout(client: *Client, update: ClientLayoutUpdateType) !void {
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

fn receive(io: std.Io, state: *RuntimeTransportState) anyerror![]u8 {
    const bytes = try state.read(io);
    mark_module(io, .client_read);
    return bytes;
}

fn send(io: std.Io, state: *RuntimeTransportState, payload: []const u8) anyerror!void {
    mark_module(io, .client_send_start);
    defer mark_module(io, .client_send_done);
    return state.send(io, payload);
}

fn recordMessage(client: *Client, observation: DecodedObservation) void {
    if (comptime !enabled_module) {
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
        elapsed_module(observation.decode_started_ns, now_module(client.io)),
    );
}
