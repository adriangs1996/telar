//! Runtime transport: queues messages for the runtime, arms the socket read and
//! releases each completed read and write.
const data = @import("model");
const core = @import("telar-core");
const runtime_messages = @import("runtime_messages.zig");
const Client = @import("../execution/Client.zig");

/// Copies bounded pane input into the outbox; `flush` writes it.
///
/// ```zig
/// try runtime_io.sendRuntimeInput(client, .{ .pane_id = pane_id, .bytes = bytes });
/// ```
pub fn sendRuntimeInput(model: *data.ClientModel, input: core.PaneInput) !void {
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
    if (!transport.beginRead()) {
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
    const received = try client.runtime_transport.completeRead(result);
    client.telemetry.recordMessage(received);
    const status = try runtime_messages.handleServerMessage(client, received.message);

    if (status) |exit_status| {
        return exit_status;
    }

    try startRuntimeRead(client);

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
/// free; the adapter's `flush` writes the successor.
///
/// ```zig
/// try runtime_io.completeRuntimeSend(client, result);
/// ```
pub fn completeRuntimeSend(model: *data.ClientModel, result: anyerror!void) !void {
    try model.to_runtime.finishSend(result);
    model.to_host.resume_input = true;
}
