//! Runtime transport: queues messages for the runtime, arms the socket read and
//! releases each completed read and write.
const data = @import("model");
const core = @import("telar-core");
const runtime_messages = @import("runtime_messages.zig");
const runtime_link = @import("runtime_link.zig");
const limit_reached = @import("../notifications/limit_reached.zig");
const Client = @import("../execution/Client.zig");

/// Copies bounded pane input into the outbox; `flush` writes it.
///
/// ```zig
/// try runtime_io.sendRuntimeInput(client, .{ .pane_id = pane_id, .bytes = bytes });
/// ```
pub fn sendRuntimeInput(model: *data.ClientModel, input: core.PaneInput) !void {
    // Input typed while the runtime is unreachable is dropped, never replayed
    // into the next session.
    if (model.runtime_link.phase != .connected) {
        return;
    }

    if (input.bytes.len > data.input_limits.max_encoded_bytes) {
        try model.to_runtime.pushInputBatch(input.pane_id, input.bytes);
    } else {
        try model.to_runtime.pushInput(input.pane_id, input.bytes);
    }
}

/// Starts the receive loop before sending the queued bootstrap.
/// Example: `try runtime_io.startRuntimeIo(client);`
pub fn startRuntimeIo(client: *Client) !void {
    try startRuntimeRead(client);
    try client.flush();
}

/// Reserves a receive buffer and releases it if the adapter rejects the read.
/// Example: `try runtime_io.startRuntimeRead(client);`
pub fn startRuntimeRead(client: *Client) !void {
    const transport = &client.runtime_transport;
    if (transport.connection == null or !transport.beginRead()) {
        return;
    }

    client.to_workers.push(.{ .runtime_read = transport }) catch |err| {
        transport.cancelRead();

        return err;
    };
}

/// Releases one runtime read, dispatches its bounded message and rearms only
/// while the client remains alive.
///
/// ```zig
/// if (try runtime_io.receiveRuntime(client, result)) |status| return status;
/// ```
pub fn receiveRuntime(client: *Client, result: anyerror!*const data.RuntimeMessage) !?u8 {
    core.profiling.add(.client_receive, 1);
    core.mark(client.io, .client_frame);
    const received = client.runtime_transport.completeRead(result) catch |err| {
        try runtime_link.lose(client, err);
        return null;
    };
    client.telemetry.recordMessage(received);
    const status = runtime_messages.receiveServerMessage(client, &received.message) catch |err| {
        if (!core.limit_reached.isLimitError(err)) {
            return err;
        }

        // The read is re-armed before anything can fail, so the link keeps
        // reading whatever the recovery does; the resync is read from the
        // message before the next read reuses its buffer.
        const resync = limit_reached.plan(&received.message);
        startRuntimeRead(client) catch |failed| return lose(client, failed);
        try limit_reached.recover(client, resync, err);
        return null;
    };

    if (status) |exit_status| {
        return exit_status;
    }

    limit_reached.resumeGraphics(client);
    startRuntimeRead(client) catch |failed| return lose(client, failed);

    return null;
}

/// A read that cannot be re-armed loses the link, so it never shows
/// connected without reading.
fn lose(client: *Client, err: anyerror) !?u8 {
    try runtime_link.lose(client, err);
    return null;
}

/// Registers correlation before copying the request; failed delivery removes only that registration.
/// Example: `try runtime_io.sendRuntimeRequest(client, delivery);`
pub fn sendRuntimeRequest(model: *data.ClientModel, delivery: data.ConnectionDelivery) !void {
    try model.request_lifecycle.tracker.add(delivery.registration.request_id, delivery.registration.continuation);
    errdefer _ = model.request_lifecycle.tracker.take(delivery.registration.request_id);
    try model.to_runtime.push(delivery.message);
}

/// Releases one runtime write and resumes host input now that a queue slot is
/// free; the adapter's `flush` writes the successor. A failed write loses
/// the link.
///
/// ```zig
/// try runtime_io.completeRuntimeSend(client, result);
/// ```
pub fn completeRuntimeSend(client: *Client, result: anyerror!void) !void {
    client.model.to_runtime.finishSend(result) catch |err| {
        return runtime_link.lose(client, err);
    };

    client.model.to_host.resume_input = true;
    try runtime_link.closeWhenIdle(client);
}
