//! Owns one client's bounded I/O lifecycle with the runtime process.

const std = @import("std");
const core = @import("telar-core");
const client_outbox = @import("outbox.zig");

const client_mod = @import("client.zig");
const Client = client_mod;
const host_inputs = @import("host_inputs.zig");
const server_messages = @import("server_messages.zig");

const Io = std.Io;
const diagnostics = core.diagnostics;
const schema = core.schema;

pub const capacity = client_outbox.capacity;
pub const max_input_bytes = client_outbox.max_input_bytes;
pub const Message = client_outbox.Message;
pub const Snapshot = client_outbox.Snapshot;

pub const Bootstrap = struct {
    graphics_shared: bool,
    open: schema.OpenPane,
};

pub const State = struct {
    connection: *core.transport.SocketChannel,
    send_buffer: []u8,
    receive_buffer: []u8,
    outbox: client_outbox.Outbox = .{},
    receive_pending: bool = false,

    /// Allocates the two bounded frame buffers around one connected channel.
    ///
    /// ```zig
    /// var state = try State.init(gpa, connection);
    /// ```
    pub fn init(gpa: std.mem.Allocator, connection: *core.transport.SocketChannel) !State {
        const receive_buffer = try gpa.alloc(u8, core.transport.max_frame_size);
        errdefer gpa.free(receive_buffer);
        const send_buffer = try gpa.alloc(u8, core.transport.max_frame_size);

        return .{
            .connection = connection,
            .send_buffer = send_buffer,
            .receive_buffer = receive_buffer,
        };
    }

    /// Releases frame storage after the client's select has cancelled every
    /// task that borrows it.
    ///
    /// ```zig
    /// state.deinit(gpa);
    /// ```
    pub fn deinit(state: *State, gpa: std.mem.Allocator) void {
        gpa.free(state.send_buffer);
        gpa.free(state.receive_buffer);
    }

    /// Sends the ordered synchronous frames required before the event loop
    /// starts its first runtime read.
    ///
    /// ```zig
    /// try state.bootstrap(io, bootstrap);
    /// ```
    pub fn bootstrap(state: *State, io: Io, request: Bootstrap) !void {
        std.debug.assert(!state.outbox.inFlight() and state.outbox.len == 0);

        const configure = try schema.encodeConfigureGraphics(state.send_buffer, .{
            .shared = request.graphics_shared,
        });
        try state.connection.send(io, configure);

        const runtime_state = try schema.encodeRequestRuntimeState(state.send_buffer);
        try state.connection.send(io, runtime_state);

        const open = try schema.encodeOpenPane(state.send_buffer, request.open);
        try state.connection.send(io, open);
    }
};

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
    if (state.receive_pending) {
        return;
    }

    state.receive_pending = true;
    client.select.concurrent(.server, receive, .{ client.io, state }) catch |err| {
        state.receive_pending = false;

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
    client.runtime_transport.receive_pending = false;
    const payload = try result;
    const decode_started = diagnostics.now(client.io);
    const message = try schema.decodeServer(payload);
    recordMessage(client, .{
        .payload_len = payload.len,
        .message = message,
        .decode_started_ns = decode_started,
    });
    const status = server_messages.handleServerMessage(client, message) catch |err| {
        switch (message) {
            .request_failed => |failure| std.debug.print("telar runtime: {s}\n", .{failure.message}),
            else => {},
        }

        return err;
    };
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
    try client.runtime_transport.outbox.pushInput(pane_id, bytes);
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
    const payload = try state.outbox.beginSend(state.send_buffer) orelse return;
    client.select.concurrent(.sent, send, .{
        client.io,
        state.connection,
        payload,
    }) catch |err| {
        state.outbox.sendFailed();

        return err;
    };
}

fn receive(io: Io, state: *State) anyerror![]u8 {
    return state.connection.receive(io, state.receive_buffer);
}

fn send(io: Io, connection: *core.transport.SocketChannel, payload: []const u8) anyerror!void {
    return connection.send(io, payload);
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

fn testingSocketPair() ![2]core.transport.SocketChannel {
    var sockets: [2]std.c.fd_t = undefined;
    if (std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &sockets) != 0) {
        return error.SocketPairFailed;
    }

    return .{
        .init(.{ .socket = .{
            .handle = sockets[0],
            .address = .{ .ip4 = .loopback(0) },
        } }),
        .init(.{ .socket = .{
            .handle = sockets[1],
            .address = .{ .ip4 = .loopback(0) },
        } }),
    };
}

fn initWithTestingAllocator(gpa: std.mem.Allocator) !void {
    var connection: core.transport.SocketChannel = undefined;
    var state = try State.init(gpa, &connection);
    defer state.deinit(gpa);
}

test "runtime transport releases every partial frame allocation" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        initWithTestingAllocator,
        .{},
    );
}

test "runtime bootstrap emits its three frames in causal order" {
    const io = std.testing.io;
    var channels = try testingSocketPair();
    defer channels[0].deinit(io);
    defer channels[1].deinit(io);
    var state = try State.init(std.testing.allocator, &channels[0]);
    defer state.deinit(std.testing.allocator);

    try state.bootstrap(io, .{
        .graphics_shared = true,
        .open = .{
            .request_id = @enumFromInt(1),
            .size = .{ .cols = 80, .rows = 24 },
            .launch = .{ .cwd = "/work", .arguments = &.{"/bin/sh"} },
        },
    });

    var buffer: [256]u8 = undefined;
    const configure = try schema.decodeClient(try channels[1].receive(io, &buffer));
    try std.testing.expect(configure == .configure_graphics);
    try std.testing.expect(configure.configure_graphics.shared);

    const runtime_state = try schema.decodeClient(try channels[1].receive(io, &buffer));
    try std.testing.expect(runtime_state == .request_runtime_state);

    const open = try schema.decodeClient(try channels[1].receive(io, &buffer));
    try std.testing.expect(open == .open_pane);
    try std.testing.expectEqual(@as(schema.RequestId, @enumFromInt(1)), open.open_pane.request_id);
    try std.testing.expectEqualStrings("/work", open.open_pane.launch.?.cwd);
}
